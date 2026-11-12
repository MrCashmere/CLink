// LIVP archives contain a still image and a short video. Extract only those two
// resources to app-chosen filenames, never paths supplied by the archive.
use std::fs::{self, OpenOptions};
use std::io::{self, BufWriter, Read, Seek, Write};
use std::path::Path;

use anyhow::{bail, ensure, Context};
use serde::Serialize;
use zip::ZipArchive;

const MAX_LIVP_BYTES: u64 = 2 * 1024 * 1024 * 1024;
const MAX_LIVP_ENTRIES: usize = 64;

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ExtractedLivp {
    pub image_name: String,
    pub image_size: u64,
    pub video_name: String,
    pub video_size: u64,
}

pub fn extract<R: Read + Seek>(source: R, directory: &Path) -> anyhow::Result<ExtractedLivp> {
    let mut archive = ZipArchive::new(source).context("无效的 LIVP ZIP")?;
    ensure!(archive.len() <= MAX_LIVP_ENTRIES, "LIVP 条目数超限");
    let mut image = None;
    let mut video = None;
    for index in 0..archive.len() {
        let entry = archive.by_index_raw(index)?;
        if !entry.is_file() || entry.name().starts_with("__MACOSX/") {
            continue;
        }
        let base = entry.name().rsplit(['/', '\\']).next().unwrap_or("");
        if base.starts_with('.') {
            continue;
        }
        let extension = base.rsplit_once('.').map_or("", |(_, ext)| ext).to_ascii_lowercase();
        let kind = match extension.as_str() {
            "jpg" | "jpeg" | "jpe" | "heic" | "heif" | "hif" | "png" | "webp" | "avif" => &mut image,
            "mp4" | "mov" | "m4v" | "qt" => &mut video,
            _ => continue,
        };
        ensure!(kind.is_none(), "LIVP 包含多份同类型素材");
        ensure!(!entry.encrypted(), "LIVP 条目已加密");
        ensure!((1..=MAX_LIVP_BYTES).contains(&entry.size()), "LIVP 条目大小无效");
        *kind = Some((index, extension, entry.size()));
    }
    let Some((image_index, image_extension, image_size)) = image else { bail!("LIVP 缺少静态图") };
    let Some((video_index, video_extension, video_size)) = video else { bail!("LIVP 缺少视频") };
    ensure!(image_size + video_size <= MAX_LIVP_BYTES, "LIVP 解压总大小超限");

    let image_name = format!("image.{image_extension}");
    let video_name = format!("video.{video_extension}");
    let image_path = directory.join(&image_name);
    let video_path = directory.join(&video_name);
    write_entry(&mut archive, image_index, image_size, &image_path)?;
    if let Err(error) = write_entry(&mut archive, video_index, video_size, &video_path) {
        let _ = fs::remove_file(image_path);
        return Err(error);
    }
    Ok(ExtractedLivp { image_name, image_size, video_name, video_size })
}

fn write_entry<R: Read + Seek>(archive: &mut ZipArchive<R>, index: usize, size: u64, path: &Path) -> anyhow::Result<()> {
    let entry = archive.by_index(index)?;
    let file = OpenOptions::new().create_new(true).write(true).open(path)?;
    let mut output = BufWriter::new(file);
    let result = (|| -> anyhow::Result<()> {
        // Reading through EOF lets the ZIP reader check CRC. The extra byte also
        // rejects data that expands beyond the length declared in the directory.
        let copied = io::copy(&mut entry.take(size + 1), &mut output)?;
        ensure!(copied == size, "LIVP 解压后的大小与条目不符");
        output.flush()?;
        Ok(())
    })();
    drop(output);
    if result.is_err() {
        let _ = fs::remove_file(path);
    }
    result
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Cursor;
    use std::sync::atomic::{AtomicUsize, Ordering};
    use zip::write::SimpleFileOptions;
    use zip::{CompressionMethod, ZipWriter};

    #[test]
    fn extracts_after_large_header_offset_and_rejects_bad_crc() {
        static SEQUENCE: AtomicUsize = AtomicUsize::new(0);
        let directory = std::env::temp_dir().join(format!("clink-livp-{}-{}", std::process::id(),
            SEQUENCE.fetch_add(1, Ordering::Relaxed)));
        fs::create_dir(&directory).unwrap();
        let image = vec![0x42; 320 * 1024];
        let video = b"deflated test video".repeat(4096);
        let mut writer = ZipWriter::new(Cursor::new(Vec::new()));
        writer.start_file("IMG_0001.JPG", SimpleFileOptions::default()
            .compression_method(CompressionMethod::Stored)).unwrap();
        writer.write_all(&image).unwrap();
        writer.start_file("IMG_0001.MOV", SimpleFileOptions::default()
            .compression_method(CompressionMethod::Deflated)).unwrap();
        writer.write_all(&video).unwrap();
        let mut bytes = writer.finish().unwrap().into_inner();

        let result = extract(Cursor::new(&bytes), &directory).unwrap();
        assert_eq!(fs::read(directory.join(result.image_name)).unwrap(), image);
        assert_eq!(fs::read(directory.join(result.video_name)).unwrap(), video);
        fs::remove_dir_all(&directory).unwrap();
        fs::create_dir(&directory).unwrap();

        let offset = ZipArchive::new(Cursor::new(&bytes)).unwrap().by_index(0).unwrap().data_start().unwrap() as usize;
        bytes[offset] ^= 1;
        assert!(extract(Cursor::new(&bytes), &directory).is_err());
        assert_eq!(fs::read_dir(&directory).unwrap().count(), 0);
        fs::remove_dir(&directory).unwrap();
    }
}
