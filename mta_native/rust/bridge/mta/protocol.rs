//! MTA 发送端应用层协议纯函数。
//!
//! WS 消息采用 `type:id:name?json_payload` 文本格式（`?` 及 payload 可省略）。
//! 本模块只做字符串构造/解析与 JSON 序列化，不依赖任何系统能力或网络，
//! 因此可直接在 host 目标上 `cargo test --no-default-features --lib` 单测。

use serde::{Deserialize, Serialize};

/// MTA 协议版本。
pub const PROTOCOL_VERSION: i64 = 1;

/// 已解析的 WS 消息。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct WsMessage {
    /// 消息类型：action / ack 等
    pub msg_type: String,
    /// 消息 ID
    pub id: u32,
    /// 消息名：versionNegotiation / sendRequest / status 等
    pub name: String,
    /// 可选 JSON payload（无 payload 时为空串）
    pub payload: String,
}

/// 构造 `type:id:name?json_payload` 文本（payload 为空时省略 `?`）。
pub fn build_message(msg_type: &str, id: u32, name: &str, payload: Option<&str>) -> String {
    match payload {
        Some(p) if !p.is_empty() => format!("{msg_type}:{id}:{name}?{p}"),
        _ => format!("{msg_type}:{id}:{name}"),
    }
}

/// 为动作类消息构造确认文本：`action` 消息回送 `ack:<原id>:<原name>`（无 payload），
/// 其它类型返回 `None`。部分厂商接收端会等待确认后才收尾，故所有动作类消息均需确认。
pub fn build_ack(message: &WsMessage) -> Option<String> {
    if message.msg_type == "action" {
        Some(build_message("ack", message.id, &message.name, None))
    } else {
        None
    }
}

/// 校验协议标识符：仅允许 ASCII 字母数字与下划线（对齐 ArkTS `\w+`）。
fn is_identifier(text: &str) -> bool {
    !text.is_empty() && text.chars().all(|c| c.is_ascii_alphanumeric() || c == '_')
}

/// 解析 `type:id:name?json_payload`，格式非法返回 `None`。
pub fn parse_message(raw: &str) -> Option<WsMessage> {
    let (head, payload) = match raw.split_once('?') {
        Some((h, p)) => (h, p),
        None => (raw, ""),
    };
    let mut parts = head.splitn(3, ':');
    let msg_type = parts.next()?;
    let id_text = parts.next()?;
    let name = parts.next()?;
    if !is_identifier(msg_type) || !is_identifier(name) {
        return None;
    }
    let id: u32 = id_text.parse().ok()?;
    Some(WsMessage {
        msg_type: msg_type.to_string(),
        id,
        name: name.to_string(),
        payload: payload.to_string(),
    })
}

/// versionNegotiation 消息 payload（声明协议版本与支持的版本集合）。
pub fn version_negotiation_payload() -> String {
    format!("{{\"version\":{PROTOCOL_VERSION},\"versions\":[{PROTOCOL_VERSION}]}}")
}

/// sendRequest 消息 payload。
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct SendRequestPayload {
    /// 任务 ID
    pub task_id: String,
    /// 任务 ID 镜像字段：MTA 约定任务 ID 同时写入 `taskId`/`id`，仅读 `id` 的实现依赖此字段
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub id: String,
    /// 发送方 ID
    pub sender_id: String,
    /// 发送方名称
    pub sender_name: String,
    /// 主文件名（展示用）
    pub file_name: String,
    /// 文件 MIME 类型
    pub mime_type: String,
    /// 文件数
    pub file_count: usize,
    /// 总字节数
    pub total_size: u64,
    /// 缩略图路径（可选）；对端确认阶段据此拉取预览图：`/thumbnail?taskId=<id>`
    #[serde(skip_serializing_if = "Option::is_none")]
    pub thumbnail: Option<String>,
    /// 缩略图宽度（可选）；协议字段名为下划线形式，故覆盖 camelCase 重命名
    #[serde(rename = "thumbnail_width", skip_serializing_if = "Option::is_none")]
    pub thumbnail_width: Option<u32>,
    /// 缩略图高度（可选）；协议字段名为下划线形式，故覆盖 camelCase 重命名
    #[serde(rename = "thumbnail_height", skip_serializing_if = "Option::is_none")]
    pub thumbnail_height: Option<u32>,
    /// MTA 原生文本内容（可选）；缺省时不序列化
    #[serde(skip_serializing_if = "Option::is_none")]
    pub cat_share_text: Option<String>,
    /// 模拟品牌标识（可选）；缺省时不序列化
    #[serde(skip_serializing_if = "Option::is_none")]
    pub sender_brand_id: Option<u8>,
    /// 模拟品牌名称（可选）；缺省时不序列化
    #[serde(skip_serializing_if = "Option::is_none")]
    pub sender_brand: Option<String>,
}

/// 序列化 sendRequest payload 为 JSON 文本。
pub fn send_request_json(payload: &SendRequestPayload) -> String {
    serde_json::to_string(payload).unwrap_or_default()
}

/// 对端 status 报文 `type` 字段：成功类型。
const STATUS_TYPE_SUCCESS: i64 = 1;
/// 对端 status 报文 `type` 字段：终止类型（拒绝/超时等）。
const STATUS_TYPE_TERMINATED: i64 = 3;
/// 对端 status 报文 `reason` 字段：部分接收（对端仅接收了部分文件）。
const STATUS_REASON_PARTIAL: &str = "partial";
/// 对端 status 报文 `reason` 字段：用户拒绝。
const STATUS_REASON_USER_REFUSED: &str = "user refuse";
/// 对端 status 报文 `reason` 字段：超时。
const STATUS_REASON_TIMEOUT: &str = "timeout";

/// 对端传输结果：由状态报文的「类型 + 原因」组合判定，共五类。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum StatusKind {
    /// 成功类型 + 正常原因：传输完整成功
    Ok,
    /// 成功类型 + 部分接收原因：对端只接收了部分文件（不得呈现为成功）
    Partial,
    /// 终止类型 + 用户拒绝原因
    Refused,
    /// 终止类型 + 超时原因
    TimedOut,
    /// 其它/无法判定
    Other,
}

/// 解析 status payload 并按「类型 + 原因」组合分类。
///
/// 分类规则与对端实现一致：成功类型 + 部分接收原因 = 部分完成；成功类型 = 成功；
/// 终止类型 + 用户拒绝/超时原因 = 拒绝/超时；其余 = 失败。原因比对大小写不敏感。
pub fn classify_status(payload: &str) -> StatusKind {
    let value: serde_json::Value = match serde_json::from_str(payload) {
        Ok(v) => v,
        Err(_) => return StatusKind::Other,
    };
    let Some(status_type) = value.get("type").and_then(|v| v.as_i64()) else {
        return StatusKind::Other;
    };
    let reason = value.get("reason").and_then(|v| v.as_str()).unwrap_or("");
    classify_status_fields(status_type, reason)
}

/// 按类型与原因组合判定结果（原因大小写不敏感）。
fn classify_status_fields(status_type: i64, reason: &str) -> StatusKind {
    let matches = |expected: &str| reason.eq_ignore_ascii_case(expected);
    match status_type {
        STATUS_TYPE_SUCCESS => {
            if matches(STATUS_REASON_PARTIAL) {
                StatusKind::Partial
            } else {
                StatusKind::Ok
            }
        }
        STATUS_TYPE_TERMINATED => {
            if matches(STATUS_REASON_USER_REFUSED) {
                StatusKind::Refused
            } else if matches(STATUS_REASON_TIMEOUT) {
                StatusKind::TimedOut
            } else {
                StatusKind::Other
            }
        }
        _ => StatusKind::Other,
    }
}

/// 发送端取消状态消息 ID（MTA 协议 status 消息固定为 99）。
pub const CANCEL_STATUS_MESSAGE_ID: u32 = 99;

/// 构造发送端取消状态报文。
///
/// 本地取消时回送对端：`action:99:status?{"taskId":..,"type":3,"reason":"user refuse"}`。
/// 载荷复用既有 status 形态的「终止类型 + 用户拒绝原因」，对端据此识别为「对方已取消」，
/// 无需等到自身超时；对端按任意 `action` 帧处理 status，故不要求先完成版本协商。
pub fn cancel_status_message(task_id: &str) -> String {
    let task_id_json = serde_json::to_string(task_id).unwrap_or_else(|_| "\"\"".to_string());
    let payload = format!(
        "{{\"taskId\":{task_id_json},\"type\":{STATUS_TYPE_TERMINATED},\"reason\":\"{STATUS_REASON_USER_REFUSED}\"}}"
    );
    build_message("action", CANCEL_STATUS_MESSAGE_ID, "status", Some(&payload))
}

/// 提取 status payload 的 `reason` 字段（缺失返回空串）。
pub fn status_reason(payload: &str) -> String {
    let value: serde_json::Value = match serde_json::from_str(payload) {
        Ok(v) => v,
        Err(_) => return String::new(),
    };
    value
        .get("reason")
        .and_then(|v| v.as_str())
        .unwrap_or("")
        .to_string()
}

// ── 单元测试 ────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn build_with_and_without_payload() {
        assert_eq!(
            build_message("action", 0, "versionNegotiation", Some("{\"version\":1}")),
            "action:0:versionNegotiation?{\"version\":1}"
        );
        assert_eq!(
            build_message("ack", 1, "sendRequest", None),
            "ack:1:sendRequest"
        );
        assert_eq!(
            build_message("ack", 1, "sendRequest", Some("")),
            "ack:1:sendRequest"
        );
    }

    #[test]
    fn build_ack_for_action_only() {
        let action = WsMessage {
            msg_type: "action".into(),
            id: 99,
            name: "status".into(),
            payload: "{\"type\":1,\"reason\":\"ok\"}".into(),
        };
        assert_eq!(build_ack(&action), Some("ack:99:status".to_string()));

        // 动作消息无 payload 时同样回送确认
        let action_bare = WsMessage {
            msg_type: "action".into(),
            id: 7,
            name: "cancel".into(),
            payload: String::new(),
        };
        assert_eq!(build_ack(&action_bare), Some("ack:7:cancel".to_string()));

        // 非动作消息（如 ack 自身）不回送
        let ack = WsMessage {
            msg_type: "ack".into(),
            id: 1,
            name: "sendRequest".into(),
            payload: String::new(),
        };
        assert_eq!(build_ack(&ack), None);
    }

    #[test]
    fn parse_roundtrip() {
        let raw = build_message(
            "action",
            0,
            "versionNegotiation",
            Some(&version_negotiation_payload()),
        );
        let msg = parse_message(&raw).expect("应可解析");
        assert_eq!(msg.msg_type, "action");
        assert_eq!(msg.id, 0);
        assert_eq!(msg.name, "versionNegotiation");
        assert_eq!(msg.payload, "{\"version\":1,\"versions\":[1]}");
    }

    #[test]
    fn parse_without_payload() {
        let msg = parse_message("ack:1:sendRequest").expect("应可解析");
        assert_eq!(msg.msg_type, "ack");
        assert_eq!(msg.id, 1);
        assert_eq!(msg.name, "sendRequest");
        assert_eq!(msg.payload, "");
    }

    #[test]
    fn parse_invalid_returns_none() {
        assert!(parse_message("garbage").is_none());
        assert!(parse_message("action:abc:name").is_none());
        assert!(parse_message("action:1:").is_none());
        assert!(parse_message("").is_none());
    }

    #[test]
    fn send_request_json_camel_case() {
        let payload = SendRequestPayload {
            task_id: "t1".into(),
            id: "t1".into(),
            sender_id: "s1".into(),
            sender_name: "HandySend".into(),
            file_name: "a.zip".into(),
            mime_type: "application/zip".into(),
            file_count: 2,
            total_size: 1024,
            thumbnail: None,
            thumbnail_width: None,
            thumbnail_height: None,
            cat_share_text: None,
            sender_brand_id: None,
            sender_brand: None,
        };
        let json = send_request_json(&payload);
        let parsed: serde_json::Value = serde_json::from_str(&json).unwrap();
        assert_eq!(parsed["taskId"], "t1");
        // 任务 ID 同时镜像到 id 字段（兼容仅读 id 的实现）
        assert_eq!(parsed["id"], "t1");
        assert_eq!(parsed["senderId"], "s1");
        assert_eq!(parsed["senderName"], "HandySend");
        assert_eq!(parsed["fileName"], "a.zip");
        assert_eq!(parsed["mimeType"], "application/zip");
        assert_eq!(parsed["fileCount"], 2);
        assert_eq!(parsed["totalSize"], 1024);
        // 文本与品牌缺省时不序列化
        assert!(parsed.get("catShareText").is_none());
        assert!(parsed.get("senderBrandId").is_none());
        assert!(parsed.get("senderBrand").is_none());
    }

    #[test]
    fn send_request_json_with_cat_share_text() {
        let payload = SendRequestPayload {
            task_id: "t2".into(),
            id: "t2".into(),
            sender_id: "s2".into(),
            sender_name: "HandySend".into(),
            file_name: "sharedText.txt".into(),
            mime_type: "application/zip".into(),
            file_count: 1,
            total_size: 5,
            thumbnail: None,
            thumbnail_width: None,
            thumbnail_height: None,
            cat_share_text: Some("hello".into()),
            sender_brand_id: None,
            sender_brand: None,
        };
        let json = send_request_json(&payload);
        let parsed: serde_json::Value = serde_json::from_str(&json).unwrap();
        // 文本以 camelCase 字段 catShareText 序列化
        assert_eq!(parsed["catShareText"], "hello");
        // 反序列化兼容（缺失字段为 None）
        let decoded: SendRequestPayload = serde_json::from_str(&json).unwrap();
        assert_eq!(decoded.cat_share_text.as_deref(), Some("hello"));
    }

    #[test]
    fn send_request_json_with_brand() {
        let payload = SendRequestPayload {
            task_id: "t3".into(),
            id: "t3".into(),
            sender_id: "s3".into(),
            sender_name: "HandySend".into(),
            file_name: "a.zip".into(),
            mime_type: "application/zip".into(),
            file_count: 1,
            total_size: 8,
            thumbnail: None,
            thumbnail_width: None,
            thumbnail_height: None,
            cat_share_text: None,
            sender_brand_id: Some(70),
            sender_brand: Some("Samsung".into()),
        };
        let json = send_request_json(&payload);
        let parsed: serde_json::Value = serde_json::from_str(&json).unwrap();
        // 品牌以 camelCase 字段序列化
        assert_eq!(parsed["senderBrandId"], 70);
        assert_eq!(parsed["senderBrand"], "Samsung");
        // 反序列化往返一致
        let decoded: SendRequestPayload = serde_json::from_str(&json).unwrap();
        assert_eq!(decoded.sender_brand_id, Some(70));
        assert_eq!(decoded.sender_brand.as_deref(), Some("Samsung"));
    }

    #[test]
    fn send_request_json_without_brand_omits_fields_and_decodes() {
        // 仅提供原始字段的载荷反序列化仍兼容（品牌为 None）
        let legacy = "{\"taskId\":\"t4\",\"senderId\":\"s4\",\"senderName\":\"HandySend\",\"fileName\":\"a.zip\",\"mimeType\":\"application/zip\",\"fileCount\":1,\"totalSize\":1}";
        let decoded: SendRequestPayload = serde_json::from_str(legacy).unwrap();
        assert_eq!(decoded.sender_brand_id, None);
        assert_eq!(decoded.sender_brand, None);
        // 无值时序列化不产生品牌字段
        let json = send_request_json(&decoded);
        let parsed: serde_json::Value = serde_json::from_str(&json).unwrap();
        assert!(parsed.get("senderBrandId").is_none());
        assert!(parsed.get("senderBrand").is_none());
    }

    /// 缩略图字段：宽/高按协议使用下划线命名（非 camelCase），缺省时不序列化。
    #[test]
    fn send_request_json_with_thumbnail_uses_snake_case_keys() {
        let payload = SendRequestPayload {
            task_id: "t5".into(),
            id: "t5".into(),
            sender_id: "s5".into(),
            sender_name: "HandySend".into(),
            file_name: "a.jpg".into(),
            mime_type: "image/jpeg".into(),
            file_count: 1,
            total_size: 12,
            thumbnail: Some("/thumbnail?taskId=t5".into()),
            thumbnail_width: Some(240),
            thumbnail_height: Some(320),
            cat_share_text: None,
            sender_brand_id: None,
            sender_brand: None,
        };
        let json = send_request_json(&payload);
        let parsed: serde_json::Value = serde_json::from_str(&json).unwrap();
        assert_eq!(parsed["thumbnail"], "/thumbnail?taskId=t5");
        assert_eq!(parsed["thumbnail_width"], 240);
        assert_eq!(parsed["thumbnail_height"], 320);
        // 不得出现 camelCase 变体
        assert!(parsed.get("thumbnailWidth").is_none());
        assert!(parsed.get("thumbnailHeight").is_none());
        // 反序列化往返一致
        let decoded: SendRequestPayload = serde_json::from_str(&json).unwrap();
        assert_eq!(decoded.thumbnail.as_deref(), Some("/thumbnail?taskId=t5"));
        assert_eq!(decoded.thumbnail_width, Some(240));
        assert_eq!(decoded.thumbnail_height, Some(320));
    }

    /// 未提供缩略图时不产生任何缩略图字段（对端据此判定不索取预览）。
    #[test]
    fn send_request_json_without_thumbnail_omits_fields() {
        let payload = SendRequestPayload {
            task_id: "t6".into(),
            id: "t6".into(),
            sender_id: "s6".into(),
            sender_name: "HandySend".into(),
            file_name: "a.jpg".into(),
            mime_type: "image/jpeg".into(),
            file_count: 1,
            total_size: 12,
            thumbnail: None,
            thumbnail_width: None,
            thumbnail_height: None,
            cat_share_text: None,
            sender_brand_id: None,
            sender_brand: None,
        };
        let parsed: serde_json::Value = serde_json::from_str(&send_request_json(&payload)).unwrap();
        assert!(parsed.get("thumbnail").is_none());
        assert!(parsed.get("thumbnail_width").is_none());
        assert!(parsed.get("thumbnail_height").is_none());
    }

    #[test]
    fn classify_status_variants() {
        assert_eq!(
            classify_status("{\"type\":1,\"reason\":\"ok\"}"),
            StatusKind::Ok
        );
        assert_eq!(
            classify_status("{\"type\":3,\"reason\":\"user refuse\"}"),
            StatusKind::Refused
        );
        assert_eq!(classify_status("{\"type\":2}"), StatusKind::Other);
        assert_eq!(classify_status("not json"), StatusKind::Other);
        assert_eq!(classify_status("{}"), StatusKind::Other);
    }

    /// 类型 + 原因组合分类：五类结果各取一条可判定路径，并与对端语义一一对应。
    #[test]
    fn classify_status_type_and_reason_matrix() {
        // 成功类型 + 部分接收原因 → 部分完成（此前被误判为成功）
        assert_eq!(
            classify_status("{\"type\":1,\"reason\":\"partial\"}"),
            StatusKind::Partial
        );
        // 成功类型 + 正常原因/无原因 → 成功
        assert_eq!(
            classify_status("{\"type\":1,\"reason\":\"ok\"}"),
            StatusKind::Ok
        );
        assert_eq!(classify_status("{\"type\":1}"), StatusKind::Ok);
        // 终止类型 + 用户拒绝 → 拒绝
        assert_eq!(
            classify_status("{\"type\":3,\"reason\":\"user refuse\"}"),
            StatusKind::Refused
        );
        // 终止类型 + 超时 → 超时
        assert_eq!(
            classify_status("{\"type\":3,\"reason\":\"timeout\"}"),
            StatusKind::TimedOut
        );
        // 终止类型 + 其它/未知原因 → 失败
        assert_eq!(
            classify_status("{\"type\":3,\"reason\":\"unknown\"}"),
            StatusKind::Other
        );
        assert_eq!(classify_status("{\"type\":3}"), StatusKind::Other);
        // 未知类型（含携带部分接收原因）→ 失败
        assert_eq!(
            classify_status("{\"type\":9,\"reason\":\"partial\"}"),
            StatusKind::Other
        );
        assert_eq!(
            classify_status("{\"type\":\"1\",\"reason\":\"ok\"}"),
            StatusKind::Other,
            "类型字段非数字时不得误判"
        );
    }

    /// 原因比对大小写不敏感（与对端实现对 `reason` 的大小写不敏感比较一致）。
    #[test]
    fn classify_status_reason_case_insensitive() {
        assert_eq!(
            classify_status("{\"type\":1,\"reason\":\"PARTIAL\"}"),
            StatusKind::Partial
        );
        assert_eq!(
            classify_status("{\"type\":3,\"reason\":\"User Refuse\"}"),
            StatusKind::Refused
        );
        assert_eq!(
            classify_status("{\"type\":3,\"reason\":\"TIMEOUT\"}"),
            StatusKind::TimedOut
        );
    }

    /// 非 JSON / 空对象 / 非字符串原因：一律判为失败，不 panic。
    #[test]
    fn classify_status_malformed_payloads() {
        assert_eq!(classify_status(""), StatusKind::Other);
        assert_eq!(
            classify_status("{\"type\":1,\"reason\":123}"),
            StatusKind::Ok
        );
        assert_eq!(
            classify_status("{\"reason\":\"partial\"}"),
            StatusKind::Other
        );
        assert_eq!(classify_status("[1,2,3]"), StatusKind::Other);
    }

    #[test]
    fn status_reason_extraction() {
        assert_eq!(
            status_reason("{\"type\":3,\"reason\":\"user refuse\"}"),
            "user refuse"
        );
        assert_eq!(status_reason("{}"), "");
        assert_eq!(status_reason("bad"), "");
    }

    /// 发送端取消状态报文：固定 id=99、name=status，载荷为终止类型 + 用户拒绝原因，
    /// 且按既有分类规则判定为「拒绝」——对端据此呈现「对方已取消」。
    #[test]
    fn cancel_status_message_shape() {
        let raw = cancel_status_message("t1");
        assert_eq!(
            raw,
            "action:99:status?{\"taskId\":\"t1\",\"type\":3,\"reason\":\"user refuse\"}"
        );
        let parsed = parse_message(&raw).expect("应可解析");
        assert_eq!(parsed.msg_type, "action");
        assert_eq!(parsed.id, CANCEL_STATUS_MESSAGE_ID);
        assert_eq!(parsed.name, "status");
        assert_eq!(classify_status(&parsed.payload), StatusKind::Refused);
        assert_eq!(status_reason(&parsed.payload), STATUS_REASON_USER_REFUSED);
    }

    /// 任务 ID 含需转义字符时仍构造出合法 JSON（不破坏报文结构）。
    #[test]
    fn cancel_status_message_escapes_task_id() {
        let raw = cancel_status_message("t\"x");
        let parsed = parse_message(&raw).expect("应可解析");
        let value: serde_json::Value =
            serde_json::from_str(&parsed.payload).expect("载荷应为合法 JSON");
        assert_eq!(value["taskId"], "t\"x");
        assert_eq!(classify_status(&parsed.payload), StatusKind::Refused);
    }
}
