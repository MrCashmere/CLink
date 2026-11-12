//! MTA 发送端流式 ZIP 写出。
//!
//! 按 ArkTS 传入的 `files[{fdSend, path, sizeBytes, entryName}]` 清单，
//! 边读源文件边把 ZIP 字节流写入目标 writer（下载响应体），不预打包、不落临时 ZIP。
//!
//! 条目压缩方法恒为 `Deflate`（无用户开关）：对端解析器只接受压缩方法条目携带
//! 数据描述符，而无 Seek 流式写出必然产生数据描述符，故不压缩直存会让对端解析失败。
//! 所有条目统一使用同一个压缩档位（[`COMPRESSION_LEVEL`]，即压缩库允许的最快档），
//! 不按文件类型区分；原因见该常量的注释。
//!
//! ZIP 字节结构（本地头/数据描述符/中央目录/EOCD/ZIP64 五件套）由 `zip` crate
//! 8.x 的 `ZipWriter::new_stream()` 生成——无 Seek 流式模式适配响应体通道，
//! ZIP64 在条目大小或总偏移超 32 位时自动启用；CRC 由库在写出后自动计算，
//! 不再起服预计算（对端 MTA 设备同样不依赖发送端预读，参考实现 EasyShare/CatShare
//! 的 Java `ZipOutputStream` 亦为写出时计算）。
//! 进度口径为「已读源字节 ÷ 声明总大小」，每次读源后回调。
//!
//! 数据源为 ArkTS 直传的 content URI 文件描述符（`fd_send`，同进程 `File::from_raw_fd`
//! 接管读取，参照 LocalSend 路径既有机制）；`fd_send < 0` 时回退 `path`（文本条目等）。

use std::fs::File;
use std::io::{Read, Write};
use std::os::fd::FromRawFd;

use serde::Deserialize;
use zip::write::SimpleFileOptions;
use zip::CompressionMethod;
use zip::ZipWriter;

/// fd 字段缺省值：`-1` 表示不使用 fd、回退沙箱路径。
/// 不能用 `#[serde(default)]` 的 0——0 是合法 fd 号，误接管会关闭无关资源（如 stdin）。
fn unused_fd() -> i32 {
    -1
}

/// 待发送文件条目（来自 ArkTS `MtaServerConfig.files`）。
#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct MtaFileEntry {
    /// content URI 文件描述符：下载发送读取源（<0 回退 `path`）
    #[serde(default = "unused_fd")]
    pub fd_send: i32,
    /// 沙箱回退路径（文本条目、无 fd 场景）
    pub path: String,
    /// ZIP 条目名（"{序号}/{显示文件名}"）
    pub entry_name: String,
    /// 源文件修改时间（Unix 毫秒，可选）；缺省时条目时间退化为压缩基准时刻
    #[serde(default)]
    pub last_modified_ms: Option<u64>,
    /// 源文件大小（字节；ArkTS 取自已打开句柄 statSync，与将发送字节同源，供进度分母与 ZIP 大小字段）
    #[serde(default)]
    pub size_bytes: u64,
}

/// 流式写出结果：源文件总字节数与条目数。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ZipWriteResult {
    /// 源文件总字节数（进度分母）
    pub total_size: u64,
    /// 条目数
    pub entry_count: usize,
}

/// ZIP32 字段上限：达到或超过该值的单条目大小必须由库启用 ZIP64 表达
const ZIP32_MAX: u64 = 0xFFFF_FFFF;
/// 条目读写缓冲区大小（字节）
const IO_BUFFER_SIZE: usize = 256 * 1024;

/// 所有条目统一使用的压缩档位：压缩库允许的最快 Deflated 档。
///
/// 取值为 1，即 `flate2::Compression::fast()`——既有约束「压缩不得成为传输瓶颈」下
/// 唯一可用的档位。写出库把 Deflated 档位限制在 `1..=9`，传入更低档位（含"完全不压缩"
/// 的 0 档）会被库以「不支持的压缩级别」拒绝，因此无法对已压缩类型（flac/图片/压缩包等，
/// 其 Deflate 压缩比接近 0）再降档以减少无谓 CPU 开销；所有条目统一使用本档位，
/// 不按文件类型区分。若将来库放开档位下界，可考虑对已压缩类型降档。
///
/// 「不设级别」并非"无级别"——库会把它解释为库默认档，因此本设置不可删除或改写，
/// 删掉即静默退化；本文件以回归断言锁定该取值。
const COMPRESSION_LEVEL: i64 = 1;

/// 从条目名去掉 "{序号}/" 前缀取显示文件名。
pub fn display_name(entry_name: &str) -> String {
    match entry_name.split_once('/') {
        Some((_, rest)) => rest.to_string(),
        None => entry_name.to_string(),
    }
}

/// 由 Unix 毫秒编码 ZIP 条目时间（`zip::DateTime`）。
///
/// 缺失、非法或超出 ZIP 可表示区间（1980–2107）时退化为 ZIP 缺省时刻
/// 1980-01-01 00:00:00，保证与中央目录使用同一时间来源。
fn entry_date_time(last_modified_ms: Option<u64>) -> zip::DateTime {
    let default = zip::DateTime::default();
    let ms = match last_modified_ms {
        Some(value) if value > 0 => value,
        _ => return default,
    };
    let seconds = (ms / 1000) as i64;
    let datetime = match time::OffsetDateTime::from_unix_timestamp(seconds) {
        Ok(value) => value,
        Err(_) => return default,
    };
    let year = datetime.year();
    if !(1980..=2107).contains(&year) {
        return default;
    }
    match zip::DateTime::from_date_and_time(
        year as u16,
        datetime.month() as u8,
        datetime.day(),
        datetime.hour(),
        datetime.minute(),
        datetime.second(),
    ) {
        Ok(value) => value,
        Err(_) => default,
    }
}

/// 打开条目数据源：`fd_send >= 0` 时接管该 fd（读毕/错误时关闭），否则按路径打开。
/// 接管 fd 前回调 `on_fd_taken`（携带条目索引）并在同一临界区内登记"该 fd 已移交"，
/// 回调返回 false 表示该 fd 已被停止路径回收，此时不得再 `from_raw_fd`（否则双关）。
fn open_source<F>(
    entry: &MtaFileEntry,
    entry_index: usize,
    on_fd_taken: &mut F,
) -> anyhow::Result<File>
where
    F: FnMut(usize) -> bool,
{
    if entry.fd_send >= 0 {
        // 与停止路径共用同一互斥量：登记与「关闭未消费 fd」互斥，
        // 二者只有一个能接管该 fd，消除 check 与 from_raw_fd 之间的竞态
        if !on_fd_taken(entry_index) {
            anyhow::bail!(
                "发送 fd 已被停止路径回收 {}: {}",
                entry.entry_name,
                entry.fd_send
            );
        }
        // SAFETY：fd 由 ArkTS 打开并移交所有权；本函数返回的 File 读毕（EOF/错误）时关闭，
        // 后续不再由 ArkTS 或任何其他路径触碰（server 停止路径仅关闭未消费的 fd，见 mod.rs）。
        let file = unsafe { File::from_raw_fd(entry.fd_send) };
        return Ok(file);
    }
    File::open(&entry.path).map_err(|e| anyhow::anyhow!("打开待发送文件失败 {}: {e}", entry.path))
}

/// 按文件清单把 ZIP 字节流写入 `writer`，返回源文件总大小与条目数。
///
/// 内部用 `zip` crate 的 `ZipWriter::new_stream()`（无 Seek 流式模式）写出标准 ZIP，
/// 所有条目以 `Deflated` 写出并统一使用同一压缩档位（[`COMPRESSION_LEVEL`]），ZIP64
/// 在单条目大小或总偏移超 32 位时自动启用；CRC 由库在条目写完时自动计算。
/// `on_source_bytes` 在条目数据写出过程中被调用，参数为累计已读源字节数，
/// 供发送进度上报（口径为"已读源字节 ÷ 声明总大小"）。写出失败时向上返回错误，
/// 由响应体收尾，不挂起连接。
pub fn write_zip_stream<W, F>(
    writer: &mut W,
    files: &[MtaFileEntry],
    on_source_bytes: F,
) -> anyhow::Result<ZipWriteResult>
where
    W: Write,
    F: FnMut(u64),
{
    // 无需登记 fd 接管的调用方（测试/接收侧）走「恒接管成功」的空回调
    write_zip_stream_with_take(writer, files, on_source_bytes, |_| true)
}

/// [`write_zip_stream`] 的带 fd 接管登记版本：接管第 index 个条目的 fd 前回调
/// `on_fd_taken(index)`，在回调内以互斥临界区完成「检查 + 登记」并返回是否接管成功
/// （false 表示该 fd 已被停止路径回收，不得再接管）。发送侧据此把 `fds_consumed[index]`
/// 置位——仅在实际接管时置位，中途失败时其后未接管的 fd 仍可由 `stop_server` 统一收尾，
/// 不泄漏；与停止路径的竞争由同一互斥量裁决，杜绝双关。
pub fn write_zip_stream_with_take<W, F, G>(
    writer: &mut W,
    files: &[MtaFileEntry],
    mut on_source_bytes: F,
    mut on_fd_taken: G,
) -> anyhow::Result<ZipWriteResult>
where
    W: Write,
    F: FnMut(u64),
    G: FnMut(usize) -> bool,
{
    if files.len() > u16::MAX as usize {
        anyhow::bail!("ZIP 条目数超过 65535");
    }
    // 流式模式：inner 不要求 Seek，ZIP64 与描述符由库按 StreamWriter 语义自动处理
    let mut zip = ZipWriter::new_stream(writer);

    let mut total_source: u64 = 0;
    let mut buffer = vec![0u8; IO_BUFFER_SIZE];

    for (entry_index, entry) in files.iter().enumerate() {
        // 压缩方法恒为 Deflated：对端解析器只接受压缩方法条目携带数据描述符，
        // 而无 Seek 流式写出必然产生数据描述符，不压缩直存会让对端中止下载。
        // 所有条目统一使用同一压缩档位、不按文件类型区分——原因（库档位下界约束，
        // 以及将来若该下界放开可对已压缩类型降档）见 COMPRESSION_LEVEL 的注释。
        let compression_level = COMPRESSION_LEVEL;
        let options = SimpleFileOptions::default()
            .compression_method(CompressionMethod::Deflated)
            .compression_level(Some(compression_level))
            // 单条目大小超 ZIP32 上限时由库启用 ZIP64；未超限保持 ZIP32 输出
            .large_file(entry.size_bytes >= ZIP32_MAX)
            .last_modified_time(entry_date_time(entry.last_modified_ms));
        zip.start_file(&entry.entry_name, options)?;

        // 单遍读出：大小已由 ArkTS 取自已打开句柄（与将发送字节同源），起服不再预读校验，
        // 下载阶段顺序读一次；每次读源后回调累计源字节（进度口径：已读源字节 ÷ 声明总大小）
        let mut source = open_source(entry, entry_index, &mut on_fd_taken)?;
        let mut entry_total: u64 = 0;
        loop {
            let read = source
                .read(&mut buffer)
                .map_err(|e| anyhow::anyhow!("读取待发送文件失败 {}: {e}", entry.entry_name))?;
            if read == 0 {
                break;
            }
            entry_total += read as u64;
            zip.write_all(&buffer[..read])?;
            total_source += read as u64;
            on_source_bytes(total_source);
        }
        if entry_total != entry.size_bytes {
            // 声明尺寸与实际读取不一致：仅记录诊断，按实际读取字节继续产出完整载荷。
            // 不得以中断写出（截断整体 ZIP，含后续条目与中央目录）的方式失败——上游尺寸
            // 来源已与句柄同源，此处仅作兜底。流式（无 Seek）写出使用数据描述符，声明尺寸
            // 不进入条目头，故继续产出完整载荷是安全的。
            log::warn!(
                "MTA 条目声明大小与实际读取不一致 entry={} 实际={} 声明={}（按实际字节继续产出）",
                entry.entry_name,
                entry_total,
                entry.size_bytes
            );
        }
        log::debug!(
            "MTA 流式写出条目 entry={} 源字节={} 压缩档={} 累计源字节={}",
            entry.entry_name,
            entry_total,
            compression_level,
            total_source
        );
    }

    zip.finish()?;

    log::debug!(
        "MTA 流式写出发送产物完成 源总字节={} 条目数={}",
        total_source,
        files.len()
    );
    Ok(ZipWriteResult {
        total_size: total_source,
        entry_count: files.len(),
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::os::fd::IntoRawFd;

    /// 构造独立临时目录。
    fn temp_dir(tag: &str) -> std::path::PathBuf {
        let dir = std::env::temp_dir().join(format!("mta_zip_stream_{tag}_{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        dir
    }

    /// 用 zip crate 的 seek 读取器解出全部条目（名/内容/时间）。
    fn read_entries(zip_bytes: &[u8]) -> Vec<(String, Vec<u8>, zip::DateTime)> {
        use std::io::Read as _;
        let mut archive = zip::ZipArchive::new(std::io::Cursor::new(zip_bytes)).unwrap();
        let mut out = Vec::new();
        for i in 0..archive.len() {
            let mut entry = archive.by_index(i).unwrap();
            let name = entry.name().to_string();
            let modified = entry.last_modified().expect("写出时已编码条目时间");
            let mut content = Vec::new();
            entry.read_to_end(&mut content).unwrap();
            out.push((name, content, modified));
        }
        out
    }

    /// 用接收端自研解析器交叉还原（名/内容/时间）。
    fn parse_with_unzip(zip_bytes: &[u8]) -> Vec<(String, Vec<u8>, i64)> {
        use crate::bridge::mta::unzip_stream::{parse_zip, PushbackReader, ZipParseOptions};
        use std::sync::atomic::AtomicU64;

        struct CollectHandler {
            entries: Vec<(String, Vec<u8>, i64)>,
        }
        impl crate::bridge::mta::unzip_stream::ZipEntryHandler for CollectHandler {
            fn handle_entry(
                &mut self,
                info: &crate::bridge::mta::unzip_stream::ZipEntryInfo,
                data: &mut dyn Read,
            ) -> Result<(), String> {
                let mut content = Vec::new();
                data.read_to_end(&mut content).map_err(|e| e.to_string())?;
                self.entries
                    .push((info.name.clone(), content, info.modified_unix_ms));
                Ok(())
            }
        }
        let mut reader = PushbackReader::new(std::io::Cursor::new(zip_bytes));
        let options = ZipParseOptions::new(100, 64 * 1024 * 1024, 0, std::sync::Arc::new(|| false));
        let progress = AtomicU64::new(0);
        let mut handler = CollectHandler {
            entries: Vec::new(),
        };
        parse_zip(&mut reader, &options, &progress, &mut handler).unwrap();
        handler.entries
    }

    #[test]
    fn display_name_strips_sequence() {
        assert_eq!(display_name("1/photo.jpg"), "photo.jpg");
        assert_eq!(display_name("plain.txt"), "plain.txt");
    }

    #[test]
    fn write_stream_produces_valid_zip() {
        let dir = temp_dir("valid");
        let a_path = dir.join("a.jpg");
        let b_path = dir.join("b.txt");
        std::fs::write(&a_path, b"hello mta").unwrap();
        std::fs::write(&b_path, b"compressible document ".repeat(50)).unwrap();
        let b_content = b"compressible document ".repeat(50);

        let files = vec![
            MtaFileEntry {
                fd_send: -1,
                path: a_path.to_string_lossy().to_string(),
                entry_name: "1/a.jpg".into(),
                last_modified_ms: None,
                size_bytes: 9,
            },
            MtaFileEntry {
                fd_send: -1,
                path: b_path.to_string_lossy().to_string(),
                entry_name: "2/b.txt".into(),
                last_modified_ms: Some(1_600_000_000_000),
                size_bytes: b_content.len() as u64,
            },
        ];
        let mut out: Vec<u8> = Vec::new();
        let result = write_zip_stream(&mut out, &files, |_| {}).unwrap();
        assert_eq!(result.entry_count, 2);
        assert_eq!(result.total_size, 9 + b_content.len() as u64);
        assert_eq!(&out[0..4], b"PK\x03\x04");

        // 压缩方法恒为 Deflated：两类条目均不得出现不压缩方法
        let mut archive = zip::ZipArchive::new(std::io::Cursor::new(out.clone())).unwrap();
        for index in 0..archive.len() {
            assert_eq!(
                archive.by_index(index).unwrap().compression(),
                CompressionMethod::Deflated,
                "所有条目必须为 Deflated（对端解析器拒绝不压缩条目携带描述符）"
            );
        }

        // zip crate 读回：条目名/内容/时间一致
        let entries = read_entries(&out);
        assert_eq!(entries.len(), 2);
        assert_eq!(entries[0].0, "1/a.jpg");
        assert_eq!(entries[0].1, b"hello mta");
        assert_eq!(entries[1].0, "2/b.txt");
        assert_eq!(entries[1].1, b_content);
        // 2020-09-13T12:26:40Z（DOS 时间可精确表示）
        let modified = entries[1].2;
        assert_eq!(modified.year(), 2020);
        assert_eq!(modified.month(), 9);
        assert_eq!(modified.day(), 13);
        assert_eq!(modified.hour(), 12);
        assert_eq!(modified.minute(), 26);
        assert_eq!(modified.second(), 40);

        // 接收端自研解析器交叉还原：内容逐字节一致
        let unzip_entries = parse_with_unzip(&out);
        assert_eq!(unzip_entries.len(), 2);
        assert_eq!(unzip_entries[0].0, "a.jpg");
        assert_eq!(unzip_entries[0].1, b"hello mta");
        assert_eq!(unzip_entries[1].0, "b.txt");
        assert_eq!(unzip_entries[1].1, b_content);
        assert_eq!(unzip_entries[1].2, 1_600_000_000_000);

        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn write_stream_reads_from_fd_and_closes_it() {
        let dir = temp_dir("fd");
        let a_path = dir.join("a.bin");
        let payload = vec![0x5au8; 1024 * 300];
        std::fs::write(&a_path, &payload).unwrap();

        // 模拟 ArkTS 直传 fd：打开后移交所有权（fd_send）
        let file = File::open(&a_path).unwrap();
        let fd_send = file.into_raw_fd();

        let files = vec![MtaFileEntry {
            fd_send,
            path: String::new(),
            entry_name: "1/a.bin".into(),
            last_modified_ms: None,
            size_bytes: payload.len() as u64,
        }];
        let mut out: Vec<u8> = Vec::new();
        let result = write_zip_stream(&mut out, &files, |_| {}).unwrap();
        assert_eq!(result.total_size, payload.len() as u64);

        // zip crate 读回内容一致
        let entries = read_entries(&out);
        assert_eq!(entries.len(), 1);
        assert_eq!(entries[0].1, payload);

        // fd 已被消费关闭：再次打开同路径仍可（避免断言操作系统行为，仅确认可重新打开）
        File::open(&a_path).unwrap();
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn write_stream_reports_source_progress() {
        let dir = temp_dir("progress");
        let a_path = dir.join("a.bin");
        let payload = vec![7u8; 1024 * 300];
        std::fs::write(&a_path, &payload).unwrap();
        let files = vec![MtaFileEntry {
            fd_send: -1,
            path: a_path.to_string_lossy().to_string(),
            entry_name: "1/a.bin".into(),
            last_modified_ms: None,
            size_bytes: payload.len() as u64,
        }];
        let mut out: Vec<u8> = Vec::new();
        let mut samples: Vec<u64> = Vec::new();
        let result = write_zip_stream(&mut out, &files, |bytes| samples.push(bytes)).unwrap();
        assert_eq!(result.total_size, payload.len() as u64);
        assert!(!samples.is_empty());
        assert_eq!(*samples.last().unwrap(), payload.len() as u64);
        // 进度单调不减
        for pair in samples.windows(2) {
            assert!(pair[1] >= pair[0]);
        }
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn write_stream_zero_byte_entry() {
        let dir = temp_dir("empty");
        let empty_path = dir.join("empty.txt");
        std::fs::write(&empty_path, b"").unwrap();
        let files = vec![MtaFileEntry {
            fd_send: -1,
            path: empty_path.to_string_lossy().to_string(),
            entry_name: "1/empty.txt".into(),
            last_modified_ms: None,
            size_bytes: 0,
        }];
        let mut out: Vec<u8> = Vec::new();
        let result = write_zip_stream(&mut out, &files, |_| {}).unwrap();
        assert_eq!(result.total_size, 0);
        assert_eq!(result.entry_count, 1);

        let entries = read_entries(&out);
        assert_eq!(entries.len(), 1);
        assert_eq!(entries[0].1, b"");

        let _ = std::fs::remove_dir_all(&dir);
    }

    /// 声明大小与实际不符时不得中断写出：仍按实际读取字节产出完整载荷（仅记录诊断），
    /// 后续条目与中央目录不受影响（载荷不得被截断）。
    #[test]
    fn write_stream_size_mismatch_still_produces_full_payload() {
        let dir = temp_dir("mismatch");
        let a_path = dir.join("a.bin");
        let b_path = dir.join("b.txt");
        let a_content = b"0123456789";
        let b_content = b"second entry";
        std::fs::write(&a_path, a_content).unwrap();
        std::fs::write(&b_path, b_content).unwrap();
        let files = vec![
            MtaFileEntry {
                fd_send: -1,
                path: a_path.to_string_lossy().to_string(),
                entry_name: "1/a.bin".into(),
                last_modified_ms: None,
                size_bytes: 5, // 声明大小小于实际
            },
            MtaFileEntry {
                fd_send: -1,
                path: b_path.to_string_lossy().to_string(),
                entry_name: "2/b.txt".into(),
                last_modified_ms: None,
                size_bytes: b_content.len() as u64,
            },
        ];
        let mut out: Vec<u8> = Vec::new();
        let result = write_zip_stream(&mut out, &files, |_| {})
            .expect("声明与实际不一致不得中断写出（否则载荷被截断）");
        assert_eq!(
            result.total_size,
            (a_content.len() + b_content.len()) as u64
        );
        assert_eq!(result.entry_count, 2);
        let entries = read_entries(&out);
        assert_eq!(entries.len(), 2);
        assert_eq!(entries[0].1, a_content);
        assert_eq!(entries[1].1, b_content);
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn write_stream_missing_source_errors() {
        let files = vec![MtaFileEntry {
            fd_send: -1,
            path: "/nonexistent/mta-file".into(),
            entry_name: "1/x".into(),
            last_modified_ms: None,
            size_bytes: 1,
        }];
        let mut out: Vec<u8> = Vec::new();
        assert!(write_zip_stream(&mut out, &files, |_| {}).is_err());
    }

    /// 条目数超过 ZIP32 上限（65535）时立即失败，不进入写出（库不写 ZIP64 结束记录）。
    #[test]
    fn entry_count_over_u16_max_errors() {
        let files: Vec<MtaFileEntry> = (0..=u16::MAX as usize)
            .map(|index| MtaFileEntry {
                fd_send: -1,
                path: String::new(),
                entry_name: format!("{index}/x"),
                last_modified_ms: None,
                size_bytes: 0,
            })
            .collect();
        let mut out: Vec<u8> = Vec::new();
        let error = write_zip_stream(&mut out, &files, |_| {}).unwrap_err();
        assert!(error.to_string().contains("65535"));
    }

    /// 混合批次（媒体 + 文本 + 视频）所有条目统一压缩方法与档位，
    /// 同一 ZIP 内所有条目压缩方法恒为 Deflated，接收端逐文件还原一致。
    #[test]
    fn mixed_batch_per_entry_method_and_roundtrip() {
        let dir = temp_dir("mixed");
        let photo = b"jpeg bytes payload".repeat(64);
        let document = "mixed batch text document line\n".repeat(200).into_bytes();
        let video = b"mp4 frame data".repeat(96);
        let photo_path = dir.join("photo.jpg");
        let doc_path = dir.join("report.txt");
        let video_path = dir.join("clip.mp4");
        std::fs::write(&photo_path, &photo).unwrap();
        std::fs::write(&doc_path, &document).unwrap();
        std::fs::write(&video_path, &video).unwrap();

        let files = vec![
            MtaFileEntry {
                fd_send: -1,
                path: photo_path.to_string_lossy().to_string(),
                entry_name: "1/photo.jpg".into(),
                last_modified_ms: Some(1_600_000_000_000),
                size_bytes: photo.len() as u64,
            },
            MtaFileEntry {
                fd_send: -1,
                path: doc_path.to_string_lossy().to_string(),
                entry_name: "2/report.txt".into(),
                last_modified_ms: Some(1_600_000_000_000),
                size_bytes: document.len() as u64,
            },
            MtaFileEntry {
                fd_send: -1,
                path: video_path.to_string_lossy().to_string(),
                entry_name: "3/clip.mp4".into(),
                last_modified_ms: None,
                size_bytes: video.len() as u64,
            },
        ];
        let mut out: Vec<u8> = Vec::new();
        let result = write_zip_stream(&mut out, &files, |_| {}).unwrap();
        assert_eq!(
            result.total_size,
            (photo.len() + document.len() + video.len()) as u64
        );
        assert_eq!(result.entry_count, 3);

        // zip crate 读回：所有条目压缩方法恒为 Deflated（不得出现 Stored）
        let mut archive = zip::ZipArchive::new(std::io::Cursor::new(out.clone())).unwrap();
        assert_eq!(archive.len(), 3);
        for index in 0..archive.len() {
            assert_eq!(
                archive.by_index(index).unwrap().compression(),
                CompressionMethod::Deflated,
                "混合批次所有条目必须为 Deflated（出现 Stored 即对端解析失败）"
            );
        }

        // 接收端解析器逐文件还原：内容逐字节一致、时间戳保持现有行为
        let entries = parse_with_unzip(&out);
        assert_eq!(entries.len(), 3);
        assert_eq!(entries[0].0, "photo.jpg");
        assert_eq!(entries[0].1, photo);
        assert_eq!(entries[0].2, 1_600_000_000_000);
        assert_eq!(entries[1].0, "report.txt");
        assert_eq!(entries[1].1, document);
        assert_eq!(entries[1].2, 1_600_000_000_000);
        assert_eq!(entries[2].0, "clip.mp4");
        assert_eq!(entries[2].1, video);
        // 未提供修改时间的条目退化为缺省 DOS 时刻 1980-01-01 00:00:00 UTC
        assert_eq!(entries[2].2, 315_532_800_000);

        let _ = std::fs::remove_dir_all(&dir);
    }

    /// 用显式压缩级别写出单条目 Deflated ZIP；除级别外的条目参数与生产路径一致
    /// （同条目名、同时间编码、同 large_file 提示），供压缩级别语义对比使用。
    ///
    /// `level` 为 `None` 即"不设级别"，由库解释为库默认级别（Deflated 为 6）。
    fn deflated_zip_with_level(
        entry_name: &str,
        payload: &[u8],
        last_modified_ms: Option<u64>,
        level: Option<i64>,
    ) -> Vec<u8> {
        let mut out: Vec<u8> = Vec::new();
        let mut zip = ZipWriter::new_stream(&mut out);
        let options = SimpleFileOptions::default()
            .compression_method(CompressionMethod::Deflated)
            .compression_level(level)
            .large_file(payload.len() as u64 >= ZIP32_MAX)
            .last_modified_time(entry_date_time(last_modified_ms));
        zip.start_file(entry_name, options).unwrap();
        zip.write_all(payload).unwrap();
        zip.finish().unwrap();
        out
    }

    /// 在临时目录写入冗余文本，返回载荷（几十 KB 量级，为压缩级别对比留出压缩空间）。
    fn write_redundant_text(dir: &std::path::Path) -> Vec<u8> {
        let payload = "compressible document line\n".repeat(2500).into_bytes();
        std::fs::write(dir.join("report.txt"), &payload).unwrap();
        payload
    }

    /// 压缩级别防漂移（逐字节锁定）：Deflated 条目必须使用速度优先档（级别 1）。
    ///
    /// 与测试内显式指定级别 1 手工写出的 ZIP 逐字节相等。若级别设置被删除，「不设级别」
    /// 会被库解释为库默认级别 6，产物字节随之改变，本断言立即失败；改写为其他档位同理。
    /// 载荷小于读写缓冲区，生产路径与手工路径喂给 deflate 的分块一致，字节可直接比较。
    #[test]
    fn deflate_compression_level_locked_byte_for_byte() {
        let dir = temp_dir("level_bytes");
        let payload = write_redundant_text(&dir);

        let entry_name = "1/report.txt";
        let last_modified_ms = Some(1_600_000_000_000u64);
        let files = vec![MtaFileEntry {
            fd_send: -1,
            path: dir.join("report.txt").to_string_lossy().to_string(),
            entry_name: entry_name.into(),
            last_modified_ms,
            size_bytes: payload.len() as u64,
        }];
        let mut produced: Vec<u8> = Vec::new();
        write_zip_stream(&mut produced, &files, |_| {}).unwrap();

        let speed_first = deflated_zip_with_level(entry_name, &payload, last_modified_ms, Some(1));
        assert_eq!(
            produced, speed_first,
            "Deflated 条目须使用速度优先档（级别 1）：产物应与显式级别 1 逐字节一致"
        );
        // 库默认档（不设级别 → 默认 6）产物字节不同，证明确实锁定了级别语义
        let library_default = deflated_zip_with_level(entry_name, &payload, last_modified_ms, None);
        assert_ne!(
            produced, library_default,
            "产物不得等于库默认级别产物：级别设置缺失会静默退化"
        );

        let _ = std::fs::remove_dir_all(&dir);
    }

    /// 压缩级别防漂移（规模特征）：高度冗余数据下速度优先档产物应明显大于库默认档产物。
    ///
    /// 一旦级别被删除或改写为默认档，生产产物便与默认档产物同规模，本断言失败。
    #[test]
    fn deflate_speed_first_tier_grows_output_vs_library_default() {
        let dir = temp_dir("level_size");
        let payload = write_redundant_text(&dir);

        let entry_name = "1/report.txt";
        let last_modified_ms = Some(1_600_000_000_000u64);
        let files = vec![MtaFileEntry {
            fd_send: -1,
            path: dir.join("report.txt").to_string_lossy().to_string(),
            entry_name: entry_name.into(),
            last_modified_ms,
            size_bytes: payload.len() as u64,
        }];
        let mut produced: Vec<u8> = Vec::new();
        write_zip_stream(&mut produced, &files, |_| {}).unwrap();

        let library_default = deflated_zip_with_level(entry_name, &payload, last_modified_ms, None);
        assert!(
            library_default.len() < produced.len(),
            "速度优先档产物应大于库默认档：生产={} 默认档={}",
            produced.len(),
            library_default.len()
        );
        assert!(
            produced.len() as f64 >= library_default.len() as f64 * 1.05,
            "速度优先档产物应至少比库默认档大 5%：生产={} 默认档={}",
            produced.len(),
            library_default.len()
        );

        let _ = std::fs::remove_dir_all(&dir);
    }

    /// ZIP64 数据描述符签名（`PK\x07\x08`）。
    const DESCRIPTOR_SIG_BYTES: [u8; 4] = [0x50, 0x4b, 0x07, 0x08];
    /// ZIP64 结束记录签名（`PK\x06\x06`）。
    const ZIP64_EOCD_SIG: u32 = 0x0606_4b50;

    /// 取本地文件头的扩展字段字节（签名 + 名称后的 extra 区）。
    fn local_extra_fields(zip_bytes: &[u8]) -> Vec<u8> {
        assert_eq!(&zip_bytes[0..4], b"PK\x03\x04", "应以本地文件头开头");
        let name_len = u16::from_le_bytes([zip_bytes[26], zip_bytes[27]]) as usize;
        let extra_len = u16::from_le_bytes([zip_bytes[28], zip_bytes[29]]) as usize;
        let start = 30 + name_len;
        zip_bytes[start..start + extra_len].to_vec()
    }

    /// 扩展字段是否含 ZIP64（header id 0x0001）。
    fn extra_has_zip64(extra: &[u8]) -> bool {
        let mut index = 0usize;
        while index + 4 <= extra.len() {
            let header_id = u16::from_le_bytes([extra[index], extra[index + 1]]);
            let length = u16::from_le_bytes([extra[index + 2], extra[index + 3]]) as usize;
            if header_id == 0x0001 {
                return true;
            }
            index += 4 + length;
        }
        false
    }

    /// 取 ZIP64 数据描述符中的 64 位压缩大小。
    fn descriptor_csize64(zip_bytes: &[u8]) -> u64 {
        let pos = zip_bytes
            .windows(4)
            .rposition(|window| window == DESCRIPTOR_SIG_BYTES)
            .expect("应存在数据描述符签名");
        let mut buf = [0u8; 8];
        buf.copy_from_slice(&zip_bytes[pos + 8..pos + 16]);
        u64::from_le_bytes(buf)
    }

    /// 取 ZIP64 数据描述符中的 64 位原始大小。
    fn descriptor_usize64(zip_bytes: &[u8]) -> u64 {
        let pos = zip_bytes
            .windows(4)
            .rposition(|window| window == DESCRIPTOR_SIG_BYTES)
            .expect("应存在数据描述符签名");
        let mut buf = [0u8; 8];
        buf.copy_from_slice(&zip_bytes[pos + 16..pos + 24]);
        u64::from_le_bytes(buf)
    }

    /// 用库直接写出一条强制 ZIP64 的单条目 ZIP。
    ///
    /// 绕过 `write_zip_stream` 的大小一致性校验：host 无法产出真实 >4GiB 数据，
    /// 该选项用于强制条目级 ZIP64（扩展字段 + 64 位描述符），聚焦结构与可解压性。
    /// 压缩方法与生产路径一致（恒为 Deflated），`level` 为写出的压缩档位。
    fn zip64_zip_via_library(entry_name: &str, payload: &[u8], level: i64) -> Vec<u8> {
        let mut out: Vec<u8> = Vec::new();
        let mut zip = ZipWriter::new_stream(&mut out);
        let options = SimpleFileOptions::default()
            .compression_method(CompressionMethod::Deflated)
            .compression_level(Some(level))
            .large_file(true);
        zip.start_file(entry_name, options).unwrap();
        zip.write_all(payload).unwrap();
        zip.finish().unwrap();
        out
    }

    /// 小批次（未超限）输出保持 ZIP32 语义：不写 ZIP64 结束记录，本地头不含 ZIP64 扩展。
    ///
    /// 覆盖 ZIP64「条件启用」的下界：不触发 ZIP64 时输出与特性引入前功能等价。
    #[test]
    fn small_batch_stays_zip32() {
        let dir = temp_dir("zip32");
        let text_path = dir.join("a.txt");
        let photo_path = dir.join("b.jpg");
        std::fs::write(&text_path, b"hello zip32").unwrap();
        std::fs::write(&photo_path, b"jpeg bytes").unwrap();
        let files = vec![
            MtaFileEntry {
                fd_send: -1,
                path: text_path.to_string_lossy().to_string(),
                entry_name: "1/a.txt".into(),
                last_modified_ms: Some(1_600_000_000_000),
                size_bytes: 11,
            },
            MtaFileEntry {
                fd_send: -1,
                path: photo_path.to_string_lossy().to_string(),
                entry_name: "2/b.jpg".into(),
                last_modified_ms: None,
                size_bytes: 10,
            },
        ];
        let mut out: Vec<u8> = Vec::new();
        write_zip_stream(&mut out, &files, |_| {}).unwrap();

        // 无 ZIP64 结束记录，本地头扩展字段不含 ZIP64
        let has_zip64_eocd = out.windows(4).any(|window| {
            u32::from_le_bytes([window[0], window[1], window[2], window[3]]) == ZIP64_EOCD_SIG
        });
        assert!(!has_zip64_eocd, "小批次不应写 ZIP64 结束记录");
        assert!(
            !extra_has_zip64(&local_extra_fields(&out)),
            "小批次本地头不应含 ZIP64 扩展字段"
        );

        // 标准读取器与接收端解析器均可正常读回
        let entries = read_entries(&out);
        assert_eq!(entries.len(), 2);
        assert_eq!(entries[0].1, b"hello zip32");
        assert_eq!(entries[1].1, b"jpeg bytes");
        let unzip_entries = parse_with_unzip(&out);
        assert_eq!(unzip_entries.len(), 2);
        assert_eq!(unzip_entries[0].0, "a.txt");
        assert_eq!(unzip_entries[1].0, "b.jpg");

        let _ = std::fs::remove_dir_all(&dir);
    }

    /// 声明超 ZIP32 上限但实际为小数据：不再失败，按实际读取字节产出可解压的完整载荷
    /// （`large_file` 提示按声明启用 ZIP64 结构，内容仍以实际读取字节为准）。
    #[test]
    fn declared_oversize_with_small_data_still_produces_full_payload() {
        let dir = temp_dir("zip64_mismatch");
        let a_path = dir.join("big.bin");
        let content = vec![0x3cu8; 1024];
        std::fs::write(&a_path, &content).unwrap();
        let files = vec![MtaFileEntry {
            fd_send: -1,
            path: a_path.to_string_lossy().to_string(),
            entry_name: "1/big.bin".into(),
            last_modified_ms: None,
            size_bytes: ZIP32_MAX + 1,
        }];
        let mut out: Vec<u8> = Vec::new();
        write_zip_stream(&mut out, &files, |_| {})
            .expect("声明与实际不一致不得中断写出（否则载荷被截断）");
        let entries = read_entries(&out);
        assert_eq!(entries.len(), 1);
        assert_eq!(entries[0].1, content);
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// 单条目 ZIP64 覆盖：超 ZIP32 上限的单条目在本地头写 ZIP64 扩展字段、
    /// 数据描述符为 64 位变体，可被标准读取器读回，并经接收端解析器交叉还原一致。
    ///
    /// 两种条目名均覆盖（ZIP64 与统一压缩档位正交叠加），
    /// 压缩方法恒为 Deflated。真实 >4GiB 数据传输由真机验证覆盖，此处以结构断言替代。
    #[test]
    fn single_entry_zip64_structure_and_roundtrip() {
        let payload = vec![0x5au8; 1024 * 32];
        for (entry_name, base_name) in [("1/big.jpg", "big.jpg"), ("1/big.txt", "big.txt")] {
            let level = COMPRESSION_LEVEL;
            let zip_bytes = zip64_zip_via_library(entry_name, &payload, level);

            // 条目级 ZIP64 结构：本地头扩展字段含 ZIP64（0x0001）
            let extra = local_extra_fields(&zip_bytes);
            assert!(
                extra_has_zip64(&extra),
                "{entry_name} 本地头应含 ZIP64 扩展字段"
            );

            // 标准读取器读回：名称/内容一致，压缩方法恒为 Deflated
            let entries = read_entries(&zip_bytes);
            assert_eq!(entries.len(), 1);
            assert_eq!(entries[0].0, entry_name);
            assert_eq!(entries[0].1, payload);
            let mut archive =
                zip::ZipArchive::new(std::io::Cursor::new(zip_bytes.clone())).unwrap();
            assert_eq!(
                archive.by_index(0).unwrap().compression(),
                CompressionMethod::Deflated,
                "{entry_name} 压缩方法必须为 Deflated"
            );
            let compressed_size = archive.by_index(0).unwrap().compressed_size();

            // 数据描述符为 ZIP64 变体：64 位压缩大小/原始大小与实际一致
            assert_eq!(
                descriptor_csize64(&zip_bytes),
                compressed_size,
                "{entry_name} 描述符 64 位压缩大小应与标准读取器一致"
            );
            assert_eq!(
                descriptor_usize64(&zip_bytes),
                payload.len() as u64,
                "{entry_name} 描述符 64 位原始大小应为实际字节数"
            );

            // 接收端自研解析器交叉还原：内容逐字节一致
            let unzip_entries = parse_with_unzip(&zip_bytes);
            assert_eq!(unzip_entries.len(), 1);
            assert_eq!(unzip_entries[0].0, base_name);
            assert_eq!(unzip_entries[0].1, payload);
        }
    }

    /// 构造不可压缩载荷（线性同余伪随机，保证测试可复现）。
    fn incompressible_payload(len: usize) -> Vec<u8> {
        let mut state: u32 = 0x1234_5678;
        (0..len)
            .map(|_| {
                state = state.wrapping_mul(1_664_525).wrapping_add(1_013_904_223);
                (state >> 24) as u8
            })
            .collect()
    }

    /// 不可压缩载荷经生产路径写出后体积不显著大于原始数据。
    ///
    /// 以不可压缩载荷（模拟已压缩媒体、随机数据）走生产路径，断言压缩方法恒为 Deflated，
    /// 且压缩后大小接近原始大小——统一档位不因"数据压不动"而显著膨胀体积。
    #[test]
    fn incompressible_entry_stays_near_original_size() {
        let dir = temp_dir("incompressible_size");
        let payload = incompressible_payload(1024 * 1024);
        let data_path = dir.join("random.bin");
        std::fs::write(&data_path, &payload).unwrap();

        let files = vec![MtaFileEntry {
            fd_send: -1,
            path: data_path.to_string_lossy().to_string(),
            entry_name: "1/random.bin".into(),
            last_modified_ms: Some(1_600_000_000_000),
            size_bytes: payload.len() as u64,
        }];
        let mut out: Vec<u8> = Vec::new();
        write_zip_stream(&mut out, &files, |_| {}).unwrap();

        let mut archive = zip::ZipArchive::new(std::io::Cursor::new(out.clone())).unwrap();
        let entry = archive.by_index(0).unwrap();
        assert_eq!(
            entry.compression(),
            CompressionMethod::Deflated,
            "统一以压缩方法写出，不可压缩数据亦为 Deflated"
        );
        let compressed_size = entry.compressed_size();
        // deflate 只增加分块封装开销（每 64KiB 块约 5 字节），远低于 1%
        assert!(
            compressed_size as f64 <= payload.len() as f64 * 1.01,
            "不可压缩条目体积不得显著大于原始数据：原始={} 压缩后={}",
            payload.len(),
            compressed_size
        );
        drop(entry);

        // 内容与源逐字节一致
        let entries = read_entries(&out);
        assert_eq!(entries.len(), 1);
        assert_eq!(entries[0].1, payload);

        let _ = std::fs::remove_dir_all(&dir);
    }
}
