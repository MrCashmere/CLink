//! MTA 接收端 ZIP 流式解析/解压核心。
//!
//! 与传输层解耦：仅依赖 [`Read`]，顺序解析 ZIP 流（逐个读取本地文件头），
//! 把每个文件条目解压后的字节流交给 [`ZipEntryHandler`] 消费。支持 `Stored` 与
//! `Deflated` 两种压缩方法，以及带/不带签名的数据描述符与 ZIP64 扩展字段。
//!
//! 语义与安全约束：
//! - 条目名仅取文件名（`/` 与 `\` 均为分隔符，防目录穿越），空名/`.`/`..` 跳过；
//! - 目录条目忽略（仅消费其数据，不产出文件）；
//! - 强制条目数与解压总字节上限（防 zip bomb）；
//! - 每读取一段数据检查取消，取消时立即中断。
//!
//! 本模块不持有会话/线程/通道等传输层状态——下载由 `receive.rs` 驱动，本模块
//! 只是可复用的解析核心。

use std::collections::VecDeque;
use std::io::{self, Read};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Arc;

use flate2::{Decompress, FlushDecompress, Status};

// ── ZIP 结构常量 ──

/// 本地文件头签名
const LOCAL_SIG: u32 = 0x0403_4b50;
/// 中央目录头签名
const CENTRAL_SIG: u32 = 0x0201_4b50;
/// 中央目录结束记录签名
const EOCD_SIG: u32 = 0x0605_4b50;
const ZIP64_EOCD_SIG: u32 = 0x0606_4b50;
const ZIP64_LOCATOR_SIG: u32 = 0x0706_4b50;
/// 数据描述符签名
const DESCRIPTOR_SIG: u32 = 0x0807_4b50;
/// 压缩方法：不压缩
const METHOD_STORED: u16 = 0;
/// 压缩方法：deflate
const METHOD_DEFLATED: u16 = 8;
/// 通用标志位：含数据描述符
const FLAG_DATA_DESCRIPTOR: u16 = 0x0008;
/// 读写缓冲区大小（字节）
const IO_BUFFER_SIZE: usize = 64 * 1024;

/// 单个条目的解析信息（解压后大小由消费方自行统计）。
#[derive(Debug, Clone)]
pub struct ZipEntryInfo {
    /// 条目名（仅文件名，已剥离路径前缀）
    pub name: String,
    /// 条目修改时间（Unix 毫秒；不可用时为 0）
    pub modified_unix_ms: i64,
}

/// 解析上限与取消检查。
#[derive(Clone)]
pub struct ZipParseOptions {
    /// 允许的最大文件条目数（目录与非法名条目不计入）
    pub max_entries: u64,
    /// 允许的解压总字节上限（防 zip bomb；0 表示不限制）
    pub max_total_bytes: u64,
    /// 允许的单条目解压字节上限（防 zip bomb；0 表示不限制）
    pub max_entry_bytes: u64,
    /// 取消检查：返回 true 时中断解析
    pub cancelled: Arc<dyn Fn() -> bool + Send + Sync>,
}

impl ZipParseOptions {
    /// 构造解析选项。
    pub fn new(
        max_entries: u64,
        max_total_bytes: u64,
        max_entry_bytes: u64,
        cancelled: Arc<dyn Fn() -> bool + Send + Sync>,
    ) -> Self {
        ZipParseOptions {
            max_entries,
            max_total_bytes,
            max_entry_bytes,
            cancelled,
        }
    }

    /// 是否已取消。
    fn is_cancelled(&self) -> bool {
        (self.cancelled)()
    }
}

/// 条目消费回调：`data` 为该条目解压后的字节流，读到 EOF 即条目结束。
pub trait ZipEntryHandler {
    /// 处理一个条目；返回错误则中断整个解析并回滚（回滚由调用方负责）。
    fn handle_entry(&mut self, info: &ZipEntryInfo, data: &mut dyn Read) -> Result<(), String>;
}

/// 顺序解析 ZIP 流，把每个文件条目交给 `handler` 消费。
///
/// `progress` 被更新为累计已解压字节数（供进度上报）；解析失败时由调用方
/// 依据自身记录的产出路径回滚已写文件。
pub fn parse_zip<R: Read, H: ZipEntryHandler>(
    reader: &mut PushbackReader<R>,
    options: &ZipParseOptions,
    progress: &AtomicU64,
    handler: &mut H,
) -> Result<(), String> {
    let mut total_written: u64 = 0;
    let mut entries: Vec<VerifiedEntry> = Vec::new();
    loop {
        if options.is_cancelled() {
            return Err("解压已取消".to_string());
        }
        let signature = match read_u32_opt(reader).map_err(io_err)? {
            Some(value) => value,
            None => return Err("ZIP 结构不完整：未找到中央目录".to_string()),
        };
        match signature {
            LOCAL_SIG => {}
            CENTRAL_SIG | EOCD_SIG | ZIP64_EOCD_SIG => {
                return verify_footer(reader, signature, &entries, options);
            }
            other => return Err(format!("未知 ZIP 结构签名 0x{other:08x}")),
        }
        if entries.len() as u64 >= options.max_entries {
            return Err(format!("ZIP 条目数超过上限 {}", options.max_entries));
        }
        let offset = reader.position - 4;

        // 本地文件头固定部分（签名之后 26 字节）
        let mut fixed = [0u8; 26];
        reader.read_exact(&mut fixed).map_err(io_err)?;
        let flags = u16::from_le_bytes([fixed[2], fixed[3]]);
        let method = u16::from_le_bytes([fixed[4], fixed[5]]);
        let dos_bits = ((fixed[9] as u32) << 24)
            | ((fixed[8] as u32) << 16)
            | ((fixed[7] as u32) << 8)
            | fixed[6] as u32;
        let header_crc = le32(&fixed, 10);
        let header_csize = le32(&fixed, 14);
        let header_usize = le32(&fixed, 18);
        let name_len = u16::from_le_bytes([fixed[22], fixed[23]]) as usize;
        let extra_len = u16::from_le_bytes([fixed[24], fixed[25]]) as usize;

        let mut name_buf = vec![0u8; name_len];
        reader.read_exact(&mut name_buf).map_err(io_err)?;
        let mut extra = vec![0u8; extra_len];
        reader.read_exact(&mut extra).map_err(io_err)?;

        let raw_name = String::from_utf8_lossy(&name_buf).to_string();
        let has_descriptor = flags & FLAG_DATA_DESCRIPTOR != 0;
        let zip64_extra = extra_zip64(&extra)?;
        let zip64 = zip64_extra.is_some();
        let (uncompressed_size, compressed_size) =
            zip_sizes(header_usize, header_csize, zip64_extra.unwrap_or_default())?;
        let data_start = reader.position;
        let is_dir = raw_name.ends_with('/') || raw_name.ends_with('\\');
        let base_name = if is_dir {
            None
        } else {
            sanitize_base_name(&raw_name)
        };

        // 构造条目数据读取器：Stored 按本地头声明长度读取，Deflated 以 deflate 流结束为界
        let entry_reader: Box<dyn Read + '_> = match method {
            METHOD_STORED => {
                if has_descriptor && compressed_size == 0 {
                    // 本地头未声明长度：以数据描述符为界（描述符由本函数统一消费）
                    Box::new(StoredDescriptorReader::new(reader, zip64))
                } else {
                    Box::new(StoredReader {
                        reader,
                        remaining: compressed_size,
                    })
                }
            }
            METHOD_DEFLATED => Box::new(InflateReader::new(reader)),
            other => return Err(format!("不支持的压缩方法 {other}")),
        };
        let mut counting = CountingReader {
            inner: entry_reader,
            progress,
            total: &mut total_written,
            max_total: options.max_total_bytes,
            entry: 0,
            crc: crc32fast::Hasher::new(),
            max_entry: options.max_entry_bytes,
            cancelled: &options.cancelled,
        };

        if let Some(name) = base_name {
            let info = ZipEntryInfo {
                name,
                modified_unix_ms: decode_dos_bits(dos_bits),
            };
            handler
                .handle_entry(&info, &mut counting)
                .map_err(|e| cancel_aware(options, e))?;
        }

        // 消费条目剩余数据（handler 未读完时），保证条目边界对齐
        let mut sink = io::sink();
        io::copy(&mut counting, &mut sink).map_err(|e| cancel_aware(options, io_err(e)))?;
        let actual_size = counting.entry;
        let actual_crc = std::mem::take(&mut counting.crc).finalize();
        drop(counting);
        let actual_compressed = reader.position - data_start;
        let (crc, compressed, size) = if has_descriptor {
            read_descriptor(reader, zip64)?
        } else {
            (header_crc, compressed_size, uncompressed_size)
        };
        if (crc, compressed, size) != (actual_crc, actual_compressed, actual_size) {
            return Err(format!("ZIP 条目校验失败：{raw_name}"));
        }
        entries.push(VerifiedEntry { offset, name: name_buf, method, crc, compressed, size });
    }
}

#[derive(PartialEq, Eq)]
struct VerifiedEntry {
    offset: u64,
    name: Vec<u8>,
    method: u16,
    crc: u32,
    compressed: u64,
    size: u64,
}

fn le16(bytes: &[u8], at: usize) -> u16 {
    u16::from_le_bytes(bytes[at..at + 2].try_into().unwrap())
}
fn le32(bytes: &[u8], at: usize) -> u32 {
    u32::from_le_bytes(bytes[at..at + 4].try_into().unwrap())
}
fn le64(bytes: &[u8], at: usize) -> u64 {
    u64::from_le_bytes(bytes[at..at + 8].try_into().unwrap())
}

fn zip_sizes(size: u32, compressed: u32, extra: &[u8]) -> Result<(u64, u64), String> {
    let size64 = size == u32::MAX;
    let compressed64 = compressed == u32::MAX;
    let required = (usize::from(size64) + usize::from(compressed64)) * 8;
    if extra.len() < required { return Err("ZIP64 大小字段不完整".into()); }
    Ok((
        if size64 { le64(extra, 0) } else { u64::from(size) },
        if compressed64 { le64(extra, usize::from(size64) * 8) } else { u64::from(compressed) },
    ))
}

fn verify_footer<R: Read>(
    reader: &mut PushbackReader<R>,
    mut sig: u32,
    entries: &[VerifiedEntry],
    options: &ZipParseOptions,
) -> Result<(), String> {
    let start = reader.position - 4;
    let mut seen = vec![false; entries.len()];
    let mut count = 0u64;
    while sig == CENTRAL_SIG {
        if options.is_cancelled() { return Err("解压已取消".into()); }
        if count >= entries.len() as u64 { return Err("ZIP 中央目录条目数不符".into()); }
        let mut fixed = [0u8; 42];
        reader.read_exact(&mut fixed).map_err(io_err)?;
        if le16(&fixed, 30) != 0 { return Err("不支持跨磁盘 ZIP".into()); }
        let mut name = vec![0u8; le16(&fixed, 24) as usize];
        let mut extra = vec![0u8; le16(&fixed, 26) as usize];
        reader.read_exact(&mut name).map_err(io_err)?;
        reader.read_exact(&mut extra).map_err(io_err)?;
        skip_exact(reader, u64::from(le16(&fixed, 28)))?;
        let zip64 = extra_zip64(&extra)?.unwrap_or_default();
        let size32 = le32(&fixed, 20);
        let compressed32 = le32(&fixed, 16);
        let (size, compressed) = zip_sizes(size32, compressed32, zip64)?;
        let offset32 = le32(&fixed, 38);
        let offset = if offset32 == u32::MAX {
            let at = (usize::from(size32 == u32::MAX) + usize::from(compressed32 == u32::MAX)) * 8;
            if zip64.len() < at + 8 { return Err("ZIP64 条目偏移缺失".into()); }
            le64(zip64, at)
        } else { u64::from(offset32) };
        let entry = VerifiedEntry { offset, name, method: le16(&fixed, 6),
            crc: le32(&fixed, 12), compressed, size };
        let index = entries.binary_search_by_key(&offset, |value| value.offset)
            .map_err(|_| "ZIP 中央目录指向未知条目".to_string())?;
        if seen[index] || entries[index] != entry { return Err("ZIP 中央目录与文件条目不符".into()); }
        seen[index] = true;
        count += 1;
        sig = read_u32_opt(reader).map_err(io_err)?.ok_or("ZIP 缺少结束记录")?;
    }
    if count != entries.len() as u64 { return Err("ZIP 中央目录条目数不符".into()); }
    let length = reader.position - 4 - start;
    let has_zip64 = sig == ZIP64_EOCD_SIG;
    if has_zip64 {
        let record_position = reader.position - 4;
        let mut record_len = [0u8; 8];
        reader.read_exact(&mut record_len).map_err(io_err)?;
        let record_len = u64::from_le_bytes(record_len);
        if !(44..=1024 * 1024).contains(&record_len) { return Err("ZIP64 结束记录长度无效".into()); }
        let mut record = [0u8; 44];
        reader.read_exact(&mut record).map_err(io_err)?;
        if le32(&record, 4) != 0 || le32(&record, 8) != 0
            || le64(&record, 12) != count || le64(&record, 20) != count
            || le64(&record, 28) != length || le64(&record, 36) != start {
            return Err("ZIP64 结束记录与中央目录不符".into());
        }
        skip_exact(reader, record_len - 44)?;
        if read_u32_opt(reader).map_err(io_err)? != Some(ZIP64_LOCATOR_SIG) {
            return Err("ZIP64 缺少定位记录".into());
        }
        let mut locator = [0u8; 16];
        reader.read_exact(&mut locator).map_err(io_err)?;
        if le32(&locator, 0) != 0 || le64(&locator, 4) != record_position || le32(&locator, 12) != 1 {
            return Err("ZIP64 定位记录无效".into());
        }
        sig = read_u32_opt(reader).map_err(io_err)?.ok_or("ZIP64 缺少结束记录")?;
    }
    if sig != EOCD_SIG { return Err("ZIP 缺少结束记录".into()); }
    let mut end = [0u8; 18];
    reader.read_exact(&mut end).map_err(io_err)?;
    let matches16 = |v: u16, n: u64| u64::from(v) == n || (has_zip64 && v == u16::MAX);
    let matches32 = |v: u32, n: u64| u64::from(v) == n || (has_zip64 && v == u32::MAX);
    if le16(&end, 0) != 0 || le16(&end, 2) != 0 || !matches16(le16(&end, 4), count)
        || !matches16(le16(&end, 6), count) || !matches32(le32(&end, 8), length)
        || !matches32(le32(&end, 12), start) {
        return Err("ZIP 结束记录与中央目录不符".into());
    }
    skip_exact(reader, u64::from(le16(&end, 16)))?;
    if reader.read(&mut [0u8; 1]).map_err(io_err)? != 0 {
        return Err("ZIP 结束记录后仍有数据".into());
    }
    Ok(())
}

/// 解压字节计数与上限校验，并把累计值写入进度。
struct CountingReader<'a> {
    inner: Box<dyn Read + 'a>,
    progress: &'a AtomicU64,
    total: &'a mut u64,
    max_total: u64,
    /// 本条目已解压字节数（每个条目独立构造读取器，天然从 0 起算）
    entry: u64,
    crc: crc32fast::Hasher,
    /// 单条目解压上限（0 表示不限制）
    max_entry: u64,
    cancelled: &'a Arc<dyn Fn() -> bool + Send + Sync>,
}

impl Read for CountingReader<'_> {
    fn read(&mut self, buf: &mut [u8]) -> io::Result<usize> {
        if (self.cancelled)() {
            // 取消失败须用不可重试的错误类别：Interrupted 表示"暂时性系统调用中断"，
            // copy_to_file 与标准库 io::copy 都会对其重试，而取消一旦触发便持续为真，
            // 用 Interrupted 会令消费方陷入无限重试（解析线程忙等、任务永不收尾）。
            return Err(io::Error::other("解压已取消"));
        }
        let read = self.inner.read(buf)?;
        if read > 0 {
            *self.total += read as u64;
            self.entry += read as u64;
            if self.max_total > 0 && *self.total > self.max_total {
                return Err(io::Error::new(
                    io::ErrorKind::InvalidData,
                    "解压总大小超过上限",
                ));
            }
            if self.max_entry > 0 && self.entry > self.max_entry {
                return Err(io::Error::new(
                    io::ErrorKind::InvalidData,
                    "条目解压大小超过上限",
                ));
            }
            self.crc.update(&buf[..read]);
            self.progress.store(*self.total, Ordering::Relaxed);
        }
        Ok(read)
    }
}

/// `Stored` 条目读取器：按本地文件头声明的长度读取，到边界即 EOF。
struct StoredReader<'a, R: Read> {
    reader: &'a mut PushbackReader<R>,
    remaining: u64,
}

impl<R: Read> Read for StoredReader<'_, R> {
    fn read(&mut self, buf: &mut [u8]) -> io::Result<usize> {
        if self.remaining == 0 || buf.is_empty() {
            return Ok(0);
        }
        let want = std::cmp::min(self.remaining, buf.len() as u64) as usize;
        let read = self.reader.read(&mut buf[..want])?;
        if read == 0 {
            return Err(io::Error::new(
                io::ErrorKind::UnexpectedEof,
                "读取 ZIP 数据失败: 条目数据意外结束",
            ));
        }
        self.remaining -= read as u64;
        Ok(read)
    }
}

/// `Stored` 条目在本地头未声明长度（`csize == 0`）时的读取器：
/// 以数据描述符（签名 `0x08074b50` + CRC/长度）为界。
///
/// 数据中偶然出现的描述符签名字节通过「声明压缩大小 == 已确认数据字节数 且
/// 声明 CRC == 已确认数据 CRC32」排除，误匹配的字节按数据交付。描述符本身不在
/// 此消费：匹配后按原样回退，仍由 `parse_zip` 统一消费，与带长度/Deflated 路径一致。
/// 无签名描述符（仅靠 `flag` 标识）无法在流式下界定，不予支持。
struct StoredDescriptorReader<'a, R: Read> {
    /// 底层读取器（描述符匹配后按原样回退，供 `parse_zip` 消费）
    reader: &'a mut PushbackReader<R>,
    /// 已确认数据的增量 CRC32
    hasher: crc32fast::Hasher,
    /// 已确认数据字节数（用于与描述符声明长度比对）
    total: u64,
    /// 已确认但尚未交付给调用方的数据
    pending: VecDeque<u8>,
    /// 读取缓冲
    buffer: Vec<u8>,
    /// 跨块保留的末尾不足签名长度的字节（可能是签名前缀）
    carry: Vec<u8>,
    /// 是否已抵达条目末尾（描述符已定位并回退）
    done: bool,
    /// 条目是否使用 ZIP64 数据描述符（长度字段为 8 字节）
    zip64: bool,
}

impl<'a, R: Read> StoredDescriptorReader<'a, R> {
    fn new(reader: &'a mut PushbackReader<R>, zip64: bool) -> Self {
        StoredDescriptorReader {
            reader,
            hasher: crc32fast::Hasher::new(),
            total: 0,
            pending: VecDeque::new(),
            buffer: vec![0u8; IO_BUFFER_SIZE],
            carry: Vec::new(),
            done: false,
            zip64,
        }
    }

    /// 推进一块：确认数据填入 `pending`，或在定位到合法描述符时置 `done`。
    ///
    /// 返回 `Ok(false)` 表示底层已 EOF 仍未找到描述符（条目数据意外结束）。
    fn advance(&mut self) -> io::Result<bool> {
        // 拆分字段借用，使 reader 与 buffer/carry 可同时可变借用
        let StoredDescriptorReader {
            reader,
            hasher,
            total,
            pending,
            buffer,
            carry,
            done,
            zip64,
        } = self;
        if *done {
            return Ok(false);
        }

        let mut data = std::mem::take(carry);
        let read = reader.read(buffer)?;
        if read == 0 {
            if data.is_empty() {
                return Ok(false);
            }
            // 尾部残余（不足签名长度）确认为数据
            hasher.update(&data);
            *total += data.len() as u64;
            pending.extend(data.iter().copied());
            return Ok(true);
        }
        data.extend_from_slice(&buffer[..read]);

        let Some(pos) = find_descriptor_signature(&data) else {
            // 未出现签名：保留末尾不足签名长度的字节到 carry，其余确认为数据
            let tail_start = data.len().saturating_sub(DESCRIPTOR_SIG_LEN - 1);
            if tail_start > 0 {
                hasher.update(&data[..tail_start]);
                *total += tail_start as u64;
                pending.extend(data[..tail_start].iter().copied());
            }
            *carry = data[tail_start..].to_vec();
            return Ok(true);
        };

        // 签名前的字节确认为数据
        if pos > 0 {
            hasher.update(&data[..pos]);
            *total += pos as u64;
            pending.extend(data[..pos].iter().copied());
        }

        // 组装候选描述符：4 字节签名 + 3 或 5 个字段
        let fixed = if *zip64 { 20 } else { 12 };
        let need = DESCRIPTOR_SIG_LEN + fixed;
        let mut descriptor: Vec<u8> = data[pos..].to_vec();
        if descriptor.len() < need {
            let mut extra = vec![0u8; need - descriptor.len()];
            reader.read_exact(&mut extra)?;
            descriptor.extend_from_slice(&extra);
        }
        if descriptor_is_valid(&descriptor, *total, hasher, *zip64) {
            // 匹配：回退整个描述符，交 parse_zip 统一消费
            reader.unread(&descriptor);
            *done = true;
            return Ok(true);
        }
        // 误匹配：签名首字节按数据处理，其余回退后重新扫描
        hasher.update(&descriptor[0..1]);
        *total += 1;
        pending.push_back(descriptor[0]);
        reader.unread(&descriptor[1..]);
        Ok(true)
    }
}

impl<R: Read> Read for StoredDescriptorReader<'_, R> {
    fn read(&mut self, buf: &mut [u8]) -> io::Result<usize> {
        if buf.is_empty() {
            return Ok(0);
        }
        let mut written = 0usize;
        loop {
            while written < buf.len() {
                match self.pending.pop_front() {
                    Some(byte) => {
                        buf[written] = byte;
                        written += 1;
                    }
                    None => break,
                }
            }
            if written == buf.len() || self.done {
                break;
            }
            if !self.advance()? {
                return Err(io::Error::new(
                    io::ErrorKind::UnexpectedEof,
                    "读取 ZIP 数据失败: 条目数据意外结束",
                ));
            }
        }
        Ok(written)
    }
}

/// 数据描述符签名字节长度。
const DESCRIPTOR_SIG_LEN: usize = 4;

/// 在字节切片中查找数据描述符签名，返回相对偏移。
fn find_descriptor_signature(data: &[u8]) -> Option<usize> {
    if data.len() < DESCRIPTOR_SIG_LEN {
        return None;
    }
    data.windows(DESCRIPTOR_SIG_LEN).position(|window| {
        u32::from_le_bytes([window[0], window[1], window[2], window[3]]) == DESCRIPTOR_SIG
    })
}

/// 校验候选描述符是否为真：声明压缩大小须等于已确认数据字节数，
/// 且声明 CRC 须与已确认数据 CRC32 一致（排除数据中偶然出现的签名字节）。
fn descriptor_is_valid(
    descriptor: &[u8],
    total: u64,
    hasher: &crc32fast::Hasher,
    zip64: bool,
) -> bool {
    let crc = u32::from_le_bytes([descriptor[4], descriptor[5], descriptor[6], descriptor[7]]);
    let csize = if zip64 {
        u64::from_le_bytes([
            descriptor[8],
            descriptor[9],
            descriptor[10],
            descriptor[11],
            descriptor[12],
            descriptor[13],
            descriptor[14],
            descriptor[15],
        ])
    } else {
        u32::from_le_bytes([descriptor[8], descriptor[9], descriptor[10], descriptor[11]]) as u64
    };
    csize == total && crc == hasher.clone().finalize()
}

/// `Deflated` 条目读取器：以 deflate 流结束位置为界，天然支持数据描述符。
struct InflateReader<'a, R: Read> {
    reader: &'a mut PushbackReader<R>,
    decompressor: Decompress,
    in_buf: Vec<u8>,
    in_start: usize,
    in_end: usize,
    done: bool,
}

impl<'a, R: Read> InflateReader<'a, R> {
    fn new(reader: &'a mut PushbackReader<R>) -> Self {
        InflateReader {
            reader,
            decompressor: Decompress::new(false),
            in_buf: vec![0u8; IO_BUFFER_SIZE],
            in_start: 0,
            in_end: 0,
            done: false,
        }
    }
}

impl<R: Read> Read for InflateReader<'_, R> {
    fn read(&mut self, buf: &mut [u8]) -> io::Result<usize> {
        if self.done || buf.is_empty() {
            return Ok(0);
        }
        let mut out_pos = 0usize;
        loop {
            if self.in_start == self.in_end {
                let read = self.reader.read(&mut self.in_buf)?;
                if read == 0 {
                    return Err(io::Error::new(
                        io::ErrorKind::UnexpectedEof,
                        "读取 ZIP 数据失败: 压缩数据意外结束",
                    ));
                }
                self.in_start = 0;
                self.in_end = read;
            }
            let before_in = self.decompressor.total_in();
            let before_out = self.decompressor.total_out();
            let status = self
                .decompressor
                .decompress(
                    &self.in_buf[self.in_start..self.in_end],
                    &mut buf[out_pos..],
                    FlushDecompress::None,
                )
                .map_err(|e| {
                    io::Error::new(io::ErrorKind::InvalidData, format!("解压失败: {e}"))
                })?;
            let used = (self.decompressor.total_in() - before_in) as usize;
            let produced = (self.decompressor.total_out() - before_out) as usize;
            self.in_start += used;
            out_pos += produced;

            if status == Status::StreamEnd {
                // 归还多读入的下一条目字节
                if self.in_start < self.in_end {
                    let leftover = self.in_buf[self.in_start..self.in_end].to_vec();
                    self.reader.unread(&leftover);
                }
                self.in_start = 0;
                self.in_end = 0;
                self.done = true;
                return Ok(out_pos);
            }
            if out_pos == buf.len() {
                return Ok(out_pos);
            }
            if used == 0 && produced == 0 {
                // 当前输入不足以产出：前移剩余输入并补充更多压缩数据
                if self.in_start < self.in_end {
                    self.in_buf.copy_within(self.in_start..self.in_end, 0);
                }
                self.in_end -= self.in_start;
                self.in_start = 0;
                if self.in_end == self.in_buf.len() {
                    return Err(io::Error::new(
                        io::ErrorKind::InvalidData,
                        "解压失败: 压缩数据无法推进",
                    ));
                }
                let read = self.reader.read(&mut self.in_buf[self.in_end..])?;
                if read == 0 {
                    return Err(io::Error::new(
                        io::ErrorKind::UnexpectedEof,
                        "读取 ZIP 数据失败: 压缩数据意外结束",
                    ));
                }
                self.in_end += read;
            }
        }
    }
}

/// Read the data descriptor (optionally signed) and return its integrity fields.
fn read_descriptor<R: Read>(reader: &mut PushbackReader<R>, zip64: bool) -> Result<(u32, u64, u64), String> {
    let mut crc = read_u32_opt(reader).map_err(io_err)?.ok_or("ZIP 缺少数据描述符")?;
    if crc == DESCRIPTOR_SIG {
        crc = read_u32_opt(reader).map_err(io_err)?.ok_or("ZIP 描述符缺少 CRC")?;
    }
    if zip64 {
        let mut sizes = [0u8; 16];
        reader.read_exact(&mut sizes).map_err(io_err)?;
        Ok((crc, le64(&sizes, 0), le64(&sizes, 8)))
    } else {
        let mut sizes = [0u8; 8];
        reader.read_exact(&mut sizes).map_err(io_err)?;
        Ok((crc, u64::from(le32(&sizes, 0)), u64::from(le32(&sizes, 4))))
    }
}

/// 读取 4 字节小端整数；输入干净结束（未读取任何字节）返回 None。
fn read_u32_opt<R: Read>(reader: &mut R) -> io::Result<Option<u32>> {
    let mut buffer = [0u8; 4];
    let mut filled = 0usize;
    while filled < 4 {
        match reader.read(&mut buffer[filled..])? {
            0 => {
                if filled == 0 {
                    return Ok(None);
                }
                return Err(io::Error::new(
                    io::ErrorKind::UnexpectedEof,
                    "读取 ZIP 签名时数据不足",
                ));
            }
            read => filled += read,
        }
    }
    Ok(Some(u32::from_le_bytes(buffer)))
}

/// 跳过指定字节数。
fn skip_exact<R: Read>(reader: &mut R, mut count: u64) -> Result<(), String> {
    let mut buffer = [0u8; 8192];
    while count > 0 {
        let want = std::cmp::min(count, buffer.len() as u64) as usize;
        reader.read_exact(&mut buffer[..want]).map_err(io_err)?;
        count -= want as u64;
    }
    Ok(())
}

fn extra_zip64(extra: &[u8]) -> Result<Option<&[u8]>, String> {
    let mut at = 0;
    while at + 4 <= extra.len() {
        let id = le16(extra, at);
        let size = le16(extra, at + 2) as usize;
        at += 4;
        if at + size > extra.len() { return Err("ZIP 扩展字段长度无效".into()); }
        if id == 0x0001 { return Ok(Some(&extra[at..at + size])); }
        at += size;
    }
    Ok(None)
}

/// 仅取文件名（`/` 与 `\` 均为分隔符）；空名、`.`、`..` 视为非法并跳过。
fn sanitize_base_name(name: &str) -> Option<String> {
    let base = name.rsplit(['/', '\\']).next().unwrap_or("").trim();
    if base.is_empty() || base == "." || base == ".." || base.contains('\0') {
        return None;
    }
    Some(base.to_string())
}

/// 将 DOS 日期时间位还原为 Unix 毫秒；不可表示时返回 0。
fn decode_dos_bits(bits: u32) -> i64 {
    let time_bits = (bits & 0xffff) as u16;
    let date_bits = (bits >> 16) as u16;
    let year = 1980 + ((date_bits >> 9) & 0x7f) as i32;
    let month_raw = ((date_bits >> 5) & 0x0f) as u8;
    let day = (date_bits & 0x1f) as u8;
    let hour = ((time_bits >> 11) & 0x1f) as u8;
    let minute = ((time_bits >> 5) & 0x3f) as u8;
    let second = ((time_bits & 0x1f) * 2) as u8;
    if month_raw == 0 || day == 0 {
        return 0;
    }
    let month = match time::Month::try_from(month_raw) {
        Ok(value) => value,
        Err(_) => return 0,
    };
    let date = match time::Date::from_calendar_date(year, month, day) {
        Ok(value) => value,
        Err(_) => return 0,
    };
    let time_value = match time::Time::from_hms(hour, minute, second) {
        Ok(value) => value,
        Err(_) => return 0,
    };
    let datetime = date.with_time(time_value).assume_utc();
    (datetime.unix_timestamp_nanos() / 1_000_000) as i64
}

/// 统一的读取错误转文本。
fn io_err(error: io::Error) -> String {
    format!("读取 ZIP 数据失败: {error}")
}

/// 取消发生时优先返回"已取消"，否则保留原始错误文本。
fn cancel_aware(options: &ZipParseOptions, message: String) -> String {
    if options.is_cancelled() {
        "解压已取消".to_string()
    } else {
        message
    }
}

/// 支持"回退"已多读字节的读取器：deflate 解码可能读入描述符/下一条目头，需归还。
pub struct PushbackReader<R> {
    inner: R,
    pushback: VecDeque<u8>,
    position: u64,
}

impl<R: Read> PushbackReader<R> {
    /// 包装底层读取器。
    pub fn new(inner: R) -> Self {
        PushbackReader {
            inner,
            pushback: VecDeque::new(),
            position: 0,
        }
    }

    /// 将 `data` 放回读取队列前端，保持原顺序。
    fn unread(&mut self, data: &[u8]) {
        self.position -= data.len() as u64;
        for byte in data.iter().rev() {
            self.pushback.push_front(*byte);
        }
    }
}

impl<R: Read> Read for PushbackReader<R> {
    fn read(&mut self, buf: &mut [u8]) -> io::Result<usize> {
        let mut written = 0usize;
        while written < buf.len() {
            match self.pushback.pop_front() {
                Some(byte) => {
                    buf[written] = byte;
                    written += 1;
                }
                None => break,
            }
        }
        if written == 0 { written = self.inner.read(buf)?; }
        self.position += written as u64;
        Ok(written)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::bridge::mta::zip_stream::{self, MtaFileEntry};
    use std::fs;
    use std::path::PathBuf;

    /// 构造独立临时目录。
    fn temp_dir(tag: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!("mta_unzip_{tag}_{}", std::process::id()));
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(&dir).unwrap();
        dir
    }

    /// 收集条目名、内容与时间的测试处理器。
    struct CollectHandler {
        entries: Vec<(String, Vec<u8>, i64)>,
    }

    impl ZipEntryHandler for CollectHandler {
        fn handle_entry(&mut self, info: &ZipEntryInfo, data: &mut dyn Read) -> Result<(), String> {
            let mut content = Vec::new();
            data.read_to_end(&mut content).map_err(|e| e.to_string())?;
            self.entries
                .push((info.name.clone(), content, info.modified_unix_ms));
            Ok(())
        }
    }

    /// 解析 ZIP 字节并返回收集结果（单条目上限不限制）。
    fn parse_bytes(
        zip_bytes: &[u8],
        max_entries: u64,
        max_total: u64,
    ) -> Result<Vec<(String, Vec<u8>, i64)>, String> {
        parse_bytes_with_entry(zip_bytes, max_entries, max_total, 0)
    }

    /// 解析 ZIP 字节并返回收集结果（可指定单条目解压上限，0 表示不限制）。
    fn parse_bytes_with_entry(
        zip_bytes: &[u8],
        max_entries: u64,
        max_total: u64,
        max_entry: u64,
    ) -> Result<Vec<(String, Vec<u8>, i64)>, String> {
        let mut reader = PushbackReader::new(io::Cursor::new(zip_bytes));
        let options = ZipParseOptions::new(max_entries, max_total, max_entry, Arc::new(|| false));
        let progress = AtomicU64::new(0);
        let mut handler = CollectHandler {
            entries: Vec::new(),
        };
        parse_zip(&mut reader, &options, &progress, &mut handler)?;
        Ok(handler.entries)
    }

    fn append_footer(out: &mut Vec<u8>, name: &[u8], method: u16, crc: u32, compressed: usize, size: usize) {
        let start = out.len() as u32;
        let mut central = [0u8; 46];
        central[..4].copy_from_slice(&CENTRAL_SIG.to_le_bytes());
        central[10..12].copy_from_slice(&method.to_le_bytes());
        central[16..20].copy_from_slice(&crc.to_le_bytes());
        central[20..24].copy_from_slice(&(compressed as u32).to_le_bytes());
        central[24..28].copy_from_slice(&(size as u32).to_le_bytes());
        central[28..30].copy_from_slice(&(name.len() as u16).to_le_bytes());
        out.extend_from_slice(&central);
        out.extend_from_slice(name);
        let length = out.len() as u32 - start;
        let mut end = [0u8; 22];
        end[..4].copy_from_slice(&EOCD_SIG.to_le_bytes());
        end[8..10].copy_from_slice(&1u16.to_le_bytes());
        end[10..12].copy_from_slice(&1u16.to_le_bytes());
        end[12..16].copy_from_slice(&length.to_le_bytes());
        end[16..20].copy_from_slice(&start.to_le_bytes());
        out.extend_from_slice(&end);
    }

    #[test]
    fn rejects_bare_end_signature_and_corrupted_entry() {
        assert!(parse_bytes(&EOCD_SIG.to_le_bytes(), 10, 1024).is_err());
        let mut archive = stored_zip_with_descriptor("a.txt", b"correct");
        assert!(parse_bytes(&archive, 10, 1024).is_ok());
        archive[35] ^= 1;
        assert!(parse_bytes(&archive, 10, 1024).is_err());
    }

    /// 构造单条 Deflated + 数据描述符的 ZIP（模拟原生 MTA 发送端）。
    fn deflated_zip_with_descriptor(name: &str, data: &[u8]) -> Vec<u8> {
        use flate2::write::DeflateEncoder;
        use flate2::Compression;
        use std::io::Write;

        let mut encoder = DeflateEncoder::new(Vec::new(), Compression::default());
        encoder.write_all(data).unwrap();
        let compressed = encoder.finish().unwrap();
        let crc = crc32fast::hash(data);
        let flags: u16 = FLAG_DATA_DESCRIPTOR;
        let name_bytes = name.as_bytes();

        let mut out: Vec<u8> = Vec::new();
        // 本地文件头：方法 8，长度/CRC 置 0
        out.extend_from_slice(&LOCAL_SIG.to_le_bytes());
        out.extend_from_slice(&20u16.to_le_bytes());
        out.extend_from_slice(&flags.to_le_bytes());
        out.extend_from_slice(&METHOD_DEFLATED.to_le_bytes());
        out.extend_from_slice(&0u16.to_le_bytes()); // 时间
        out.extend_from_slice(&0x0021u16.to_le_bytes()); // 日期 1980-01-01
        out.extend_from_slice(&0u32.to_le_bytes()); // crc
        out.extend_from_slice(&0u32.to_le_bytes()); // csize
        out.extend_from_slice(&0u32.to_le_bytes()); // usize
        out.extend_from_slice(&(name_bytes.len() as u16).to_le_bytes());
        out.extend_from_slice(&0u16.to_le_bytes());
        out.extend_from_slice(name_bytes);
        // 压缩数据
        out.extend_from_slice(&compressed);
        // 数据描述符（含签名）
        out.extend_from_slice(&DESCRIPTOR_SIG.to_le_bytes());
        out.extend_from_slice(&crc.to_le_bytes());
        out.extend_from_slice(&(compressed.len() as u32).to_le_bytes());
        out.extend_from_slice(&(data.len() as u32).to_le_bytes());
        append_footer(&mut out, name_bytes, METHOD_DEFLATED, crc, compressed.len(), data.len());
        out
    }

    #[test]
    fn stored_roundtrip_content_and_time() {
        let dir = temp_dir("stored");
        let src_dir = dir.join("src");
        fs::create_dir_all(&src_dir).unwrap();
        let a_path = src_dir.join("a.txt");
        let b_path = src_dir.join("b.txt");
        fs::write(&a_path, b"hello mta").unwrap();
        fs::write(&b_path, b"second file").unwrap();
        let files = vec![
            MtaFileEntry {
                fd_send: -1,
                path: a_path.to_string_lossy().to_string(),
                entry_name: "1/a.txt".into(),
                last_modified_ms: Some(1_600_000_000_000),
                size_bytes: 9,
            },
            MtaFileEntry {
                fd_send: -1,
                path: b_path.to_string_lossy().to_string(),
                entry_name: "2/b.txt".into(),
                last_modified_ms: None,
                size_bytes: 11,
            },
        ];
        let mut zip_bytes: Vec<u8> = Vec::new();
        zip_stream::write_zip_stream(&mut zip_bytes, &files, |_| {}).unwrap();

        let entries = parse_bytes(&zip_bytes, 10, 1024 * 1024).unwrap();
        assert_eq!(entries.len(), 2);
        assert_eq!(entries[0].0, "a.txt");
        assert_eq!(entries[0].1, b"hello mta");
        assert_eq!(entries[0].2, 1_600_000_000_000);
        assert_eq!(entries[1].0, "b.txt");
        assert_eq!(entries[1].1, b"second file");

        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn deflated_with_data_descriptor_roundtrip() {
        let payload = "compressible payload ".repeat(500).into_bytes();
        let zip_bytes = deflated_zip_with_descriptor("0/doc.txt", &payload);
        let entries = parse_bytes(&zip_bytes, 10, 10 * 1024 * 1024).unwrap();
        assert_eq!(entries.len(), 1);
        assert_eq!(entries[0].0, "doc.txt");
        assert_eq!(entries[0].1, payload);
    }

    #[test]
    fn path_traversal_name_is_flattened() {
        let zip_bytes = deflated_zip_with_descriptor("../../evil.txt", b"evil");
        let entries = parse_bytes(&zip_bytes, 10, 1024).unwrap();
        assert_eq!(entries.len(), 1);
        assert_eq!(entries[0].0, "evil.txt");
    }

    #[test]
    fn directory_entry_is_ignored() {
        let zip_bytes = deflated_zip_with_descriptor("dir/sub/", b"");
        let entries = parse_bytes(&zip_bytes, 10, 1024).unwrap();
        assert!(entries.is_empty());
    }

    #[test]
    fn exceeds_total_bytes_limit_errors() {
        let zip_bytes = deflated_zip_with_descriptor("0/big.bin", &vec![1u8; 4096]);
        assert!(parse_bytes(&zip_bytes, 10, 1024).is_err());
    }

    /// 单条目解压字节超上限应拒绝；上限内的同一输入应正常解析。
    #[test]
    fn exceeds_entry_bytes_limit_errors() {
        let payload = vec![1u8; 4096];
        let zip_bytes = deflated_zip_with_descriptor("0/big.bin", &payload);
        // 单条目上限 1024 < 4096 实际字节：拒绝
        assert!(parse_bytes_with_entry(&zip_bytes, 10, 1024 * 1024, 1024).is_err());
        // 上限提高到实际字节数：通过
        assert!(parse_bytes_with_entry(&zip_bytes, 10, 1024 * 1024, 4096).is_ok());
    }

    /// 多条场景：单条目上限只约束单个条目，不约束累计总量。
    #[test]
    fn entry_bytes_limit_is_per_entry() {
        let dir = temp_dir("entry_limit_multi");
        let source = dir.join("a.txt");
        fs::write(&source, b"0123456789").unwrap(); // 每条约 10 字节
        let mut files = Vec::new();
        for index in 0..3 {
            files.push(MtaFileEntry {
                fd_send: -1,
                path: source.to_string_lossy().to_string(),
                entry_name: format!("{}/a{index}.jpg", index + 1), // 条目名仅用于区分多条目，与压缩方式无关
                last_modified_ms: None,
                size_bytes: 10,
            });
        }
        let mut zip_bytes: Vec<u8> = Vec::new();
        zip_stream::write_zip_stream(&mut zip_bytes, &files, |_| {}).unwrap();
        // 单条目上限 10 == 每条目字节：3 条合计 30 仍应通过
        let entries = parse_bytes_with_entry(&zip_bytes, 10, 1024 * 1024, 10).unwrap();
        assert_eq!(entries.len(), 3);
        // 单条目上限 9 < 10：拒绝
        assert!(parse_bytes_with_entry(&zip_bytes, 10, 1024 * 1024, 9).is_err());
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn exceeds_entry_limit_errors() {
        let dir = temp_dir("limit_entries");
        let source = dir.join("a.txt");
        fs::write(&source, b"x").unwrap();
        let files = vec![
            MtaFileEntry {
                fd_send: -1,
                path: source.to_string_lossy().to_string(),
                entry_name: "1/a.txt".into(),
                last_modified_ms: None,
                size_bytes: 1,
            },
            MtaFileEntry {
                fd_send: -1,
                path: source.to_string_lossy().to_string(),
                entry_name: "2/b.txt".into(),
                last_modified_ms: None,
                size_bytes: 1,
            },
        ];
        let mut zip_bytes: Vec<u8> = Vec::new();
        zip_stream::write_zip_stream(&mut zip_bytes, &files, |_| {}).unwrap();
        assert!(parse_bytes(&zip_bytes, 1, 1024 * 1024).is_err());
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn truncated_stream_errors() {
        // 合法本地头签名后立即结束：解析应报结构不完整
        assert!(parse_bytes(&LOCAL_SIG.to_le_bytes(), 10, 1024).is_err());
    }

    #[test]
    fn corrupt_deflate_stream_errors() {
        let mut zip_bytes = deflated_zip_with_descriptor("0/doc.txt", b"payload");
        // 破坏压缩数据（位于本地头 30 字节 + 名称 7 字节之后）
        let corrupt_index = 30 + "0/doc.txt".len() + 2;
        zip_bytes[corrupt_index] = 0xff;
        let result = parse_bytes(&zip_bytes, 10, 1024);
        assert!(result.is_err(), "损坏的 deflate 数据应报错");
    }

    #[test]
    fn cancelled_parse_errors() {
        let zip_bytes = deflated_zip_with_descriptor("0/doc.txt", &vec![7u8; 1024 * 64]);
        let mut reader = PushbackReader::new(io::Cursor::new(&zip_bytes));
        let options = ZipParseOptions::new(10, 10 * 1024 * 1024, 0, Arc::new(|| true));
        let progress = AtomicU64::new(0);
        let mut handler = CollectHandler {
            entries: Vec::new(),
        };
        let result = parse_zip(&mut reader, &options, &progress, &mut handler);
        assert_eq!(result.unwrap_err(), "解压已取消");
    }

    #[test]
    fn sanitize_base_name_variants() {
        assert_eq!(sanitize_base_name("1/a.txt"), Some("a.txt".to_string()));
        assert_eq!(sanitize_base_name("a\\b\\c.txt"), Some("c.txt".to_string()));
        assert_eq!(sanitize_base_name(".."), None);
        assert_eq!(sanitize_base_name("."), None);
        assert_eq!(sanitize_base_name("dir/"), None);
    }

    /// 构造 Stored + 数据描述符（含签名）的单条 ZIP：本地头 csize=0，长度在描述符中。
    fn stored_zip_with_descriptor(name: &str, data: &[u8]) -> Vec<u8> {
        let crc = crc32fast::hash(data);
        let name_bytes = name.as_bytes();
        let mut out: Vec<u8> = Vec::new();
        out.extend_from_slice(&LOCAL_SIG.to_le_bytes());
        out.extend_from_slice(&20u16.to_le_bytes());
        out.extend_from_slice(&FLAG_DATA_DESCRIPTOR.to_le_bytes());
        out.extend_from_slice(&METHOD_STORED.to_le_bytes());
        out.extend_from_slice(&0u16.to_le_bytes()); // 时间
        out.extend_from_slice(&0x0021u16.to_le_bytes()); // 日期 1980-01-01
        out.extend_from_slice(&0u32.to_le_bytes()); // crc（描述符中给出）
        out.extend_from_slice(&0u32.to_le_bytes()); // csize = 0（描述符中给出）
        out.extend_from_slice(&0u32.to_le_bytes()); // usize
        out.extend_from_slice(&(name_bytes.len() as u16).to_le_bytes());
        out.extend_from_slice(&0u16.to_le_bytes()); // extra_len
        out.extend_from_slice(name_bytes);
        out.extend_from_slice(data);
        // 数据描述符（含签名）
        out.extend_from_slice(&DESCRIPTOR_SIG.to_le_bytes());
        out.extend_from_slice(&crc.to_le_bytes());
        out.extend_from_slice(&(data.len() as u32).to_le_bytes());
        out.extend_from_slice(&(data.len() as u32).to_le_bytes());
        append_footer(&mut out, name_bytes, METHOD_STORED, crc, data.len(), data.len());
        out
    }

    #[test]
    fn stored_with_data_descriptor_roundtrip() {
        let payload = b"stored with descriptor".to_vec();
        let zip_bytes = stored_zip_with_descriptor("0/note.txt", &payload);
        let entries = parse_bytes(&zip_bytes, 10, 1024 * 1024).unwrap();
        assert_eq!(entries.len(), 1);
        assert_eq!(entries[0].0, "note.txt");
        assert_eq!(entries[0].1, payload);
    }

    #[test]
    fn stored_with_descriptor_tolerates_signature_in_data() {
        // 数据中嵌入描述符签名与假字段：不得被误判为条目结束
        let mut payload: Vec<u8> = b"prefix-".to_vec();
        payload.extend_from_slice(&DESCRIPTOR_SIG.to_le_bytes());
        payload.extend_from_slice(&[0u8; 12]);
        payload.extend_from_slice(b"-suffix");
        let zip_bytes = stored_zip_with_descriptor("0/fake.bin", &payload);
        let entries = parse_bytes(&zip_bytes, 10, 1024 * 1024).unwrap();
        assert_eq!(entries.len(), 1);
        assert_eq!(entries[0].0, "fake.bin");
        assert_eq!(entries[0].1, payload);
    }

    /// 构造 Stored + ZIP64 扩展字段 + ZIP64 数据描述符的单条 ZIP：
    /// 本地头 csize=0 且扩展字段（0x0001）给出 64 位大小，描述符字段为 64 位。
    /// `signed` 控制描述符是否带签名（Stored 仅支持带签名形态）。
    fn stored_zip64_with_descriptor(name: &str, data: &[u8], signed: bool) -> Vec<u8> {
        let crc = crc32fast::hash(data);
        let name_bytes = name.as_bytes();
        let mut out: Vec<u8> = Vec::new();
        out.extend_from_slice(&LOCAL_SIG.to_le_bytes());
        out.extend_from_slice(&45u16.to_le_bytes()); // 解压所需版本 4.5（ZIP64）
        out.extend_from_slice(&FLAG_DATA_DESCRIPTOR.to_le_bytes());
        out.extend_from_slice(&METHOD_STORED.to_le_bytes());
        out.extend_from_slice(&0u16.to_le_bytes()); // 时间
        out.extend_from_slice(&0x0021u16.to_le_bytes()); // 日期 1980-01-01
        out.extend_from_slice(&0u32.to_le_bytes()); // crc（描述符中给出）
        out.extend_from_slice(&0u32.to_le_bytes()); // csize = 0（描述符中给出）
        out.extend_from_slice(&0u32.to_le_bytes()); // usize
        out.extend_from_slice(&(name_bytes.len() as u16).to_le_bytes());
        out.extend_from_slice(&20u16.to_le_bytes()); // extra_len（ZIP64 扩展头）
        out.extend_from_slice(name_bytes);
        out.extend_from_slice(&0x0001u16.to_le_bytes()); // ZIP64 扩展头 id
        out.extend_from_slice(&16u16.to_le_bytes());
        out.extend_from_slice(&(data.len() as u64).to_le_bytes()); // 原始大小
        out.extend_from_slice(&(data.len() as u64).to_le_bytes()); // 压缩大小（Stored 相等）
        out.extend_from_slice(data);
        if signed {
            out.extend_from_slice(&DESCRIPTOR_SIG.to_le_bytes());
        }
        out.extend_from_slice(&crc.to_le_bytes());
        out.extend_from_slice(&(data.len() as u64).to_le_bytes());
        out.extend_from_slice(&(data.len() as u64).to_le_bytes());
        append_footer(&mut out, name_bytes, METHOD_STORED, crc, data.len(), data.len());
        out
    }

    /// 构造 Deflated + ZIP64 扩展字段 + ZIP64 数据描述符的单条 ZIP。
    fn deflated_zip64_with_descriptor(name: &str, data: &[u8], signed: bool) -> Vec<u8> {
        use flate2::write::DeflateEncoder;
        use flate2::Compression;
        use std::io::Write;

        let mut encoder = DeflateEncoder::new(Vec::new(), Compression::default());
        encoder.write_all(data).unwrap();
        let compressed = encoder.finish().unwrap();
        let crc = crc32fast::hash(data);
        let name_bytes = name.as_bytes();

        let mut out: Vec<u8> = Vec::new();
        out.extend_from_slice(&LOCAL_SIG.to_le_bytes());
        out.extend_from_slice(&45u16.to_le_bytes());
        out.extend_from_slice(&FLAG_DATA_DESCRIPTOR.to_le_bytes());
        out.extend_from_slice(&METHOD_DEFLATED.to_le_bytes());
        out.extend_from_slice(&0u16.to_le_bytes());
        out.extend_from_slice(&0x0021u16.to_le_bytes());
        out.extend_from_slice(&0u32.to_le_bytes()); // crc
        out.extend_from_slice(&0xFFFF_FFFFu32.to_le_bytes()); // csize = ZIP64 哨兵
        out.extend_from_slice(&0xFFFF_FFFFu32.to_le_bytes()); // usize = ZIP64 哨兵
        out.extend_from_slice(&(name_bytes.len() as u16).to_le_bytes());
        out.extend_from_slice(&20u16.to_le_bytes());
        out.extend_from_slice(name_bytes);
        out.extend_from_slice(&0x0001u16.to_le_bytes());
        out.extend_from_slice(&16u16.to_le_bytes());
        out.extend_from_slice(&(data.len() as u64).to_le_bytes());
        out.extend_from_slice(&(compressed.len() as u64).to_le_bytes());
        out.extend_from_slice(&compressed);
        if signed {
            out.extend_from_slice(&DESCRIPTOR_SIG.to_le_bytes());
        }
        out.extend_from_slice(&crc.to_le_bytes());
        out.extend_from_slice(&(compressed.len() as u64).to_le_bytes());
        out.extend_from_slice(&(data.len() as u64).to_le_bytes());
        append_footer(&mut out, name_bytes, METHOD_DEFLATED, crc, compressed.len(), data.len());
        out
    }

    /// ZIP64 字段与 64 位数据描述符：带签名（Stored/Deflated）与不带签名（Deflated）
    /// 均应正常解析并逐字节还原。
    #[test]
    fn zip64_fields_with_and_without_signature_roundtrip() {
        let stored_payload = b"stored zip64 descriptor payload".to_vec();
        let entries = parse_bytes(
            &stored_zip64_with_descriptor("0/s.bin", &stored_payload, true),
            10,
            1024 * 1024,
        )
        .unwrap();
        assert_eq!(entries.len(), 1);
        assert_eq!(entries[0].0, "s.bin");
        assert_eq!(entries[0].1, stored_payload);

        let deflated_payload = "zip64 deflated payload ".repeat(200).into_bytes();
        let signed = parse_bytes(
            &deflated_zip64_with_descriptor("0/d.txt", &deflated_payload, true),
            10,
            1024 * 1024,
        )
        .unwrap();
        assert_eq!(signed.len(), 1);
        assert_eq!(signed[0].0, "d.txt");
        assert_eq!(signed[0].1, deflated_payload);

        // 不带签名的 64 位描述符：Deflated 以压缩流结束定界，解析仍应成功
        let unsigned = parse_bytes(
            &deflated_zip64_with_descriptor("0/u.txt", &deflated_payload, false),
            10,
            1024 * 1024,
        )
        .unwrap();
        assert_eq!(unsigned.len(), 1);
        assert_eq!(unsigned[0].0, "u.txt");
        assert_eq!(unsigned[0].1, deflated_payload);
    }

    #[test]
    fn cancel_mid_entry_stops_without_busy_wait() {
        use std::sync::atomic::AtomicBool;

        // 取消发生在条目数据读取中途：后续读取须立即失败并归一为「解压已取消」，
        // 不得因 Interrupted 被消费方重试而忙等（回归保护）
        let payload = vec![9u8; 1024 * 1024];
        let zip_bytes = deflated_zip_with_descriptor("0/big.bin", &payload);
        let flag = Arc::new(AtomicBool::new(false));
        let flag_reader = flag.clone();
        let options = ZipParseOptions::new(
            10,
            100 * 1024 * 1024,
            0,
            Arc::new(move || flag_reader.load(Ordering::Relaxed)),
        );
        let mut reader = PushbackReader::new(io::Cursor::new(&zip_bytes));
        let progress = AtomicU64::new(0);

        struct CancelAfterFirstChunk {
            flag: Arc<AtomicBool>,
        }
        impl ZipEntryHandler for CancelAfterFirstChunk {
            fn handle_entry(
                &mut self,
                _info: &ZipEntryInfo,
                data: &mut dyn Read,
            ) -> Result<(), String> {
                let mut buf = [0u8; 4096];
                data.read_exact(&mut buf).map_err(|e| e.to_string())?;
                self.flag.store(true, Ordering::Relaxed);
                let mut sink = Vec::new();
                data.read_to_end(&mut sink).map_err(|e| e.to_string())?;
                Ok(())
            }
        }

        let mut handler = CancelAfterFirstChunk { flag };
        let result = parse_zip(&mut reader, &options, &progress, &mut handler);
        assert_eq!(result.unwrap_err(), "解压已取消");
    }
}
