//! 内容安全（WBS 16.3）：推送的文字经厂商通道发到系统通知栏，发之前过一遍过滤。
//! 命中的不丢通知，正文换成中性的提示，用户打开 App 在收件箱里看（收件箱只有本人可见）。
//!
//! 现在是本地关键词表；接第三方内容安全服务时再实现一个 [`ContentFilter`]。

use std::path::Path;

/// 过滤结果。
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Verdict {
    Pass,
    /// 命中，`reason` 只进日志。
    Block {
        reason: String,
    },
}

pub trait ContentFilter: Send + Sync {
    fn check(&self, text: &str) -> Verdict;
}

/// 什么都不拦。
pub struct AllowAll;

impl ContentFilter for AllowAll {
    fn check(&self, _text: &str) -> Verdict {
        Verdict::Pass
    }
}

/// 关键词表：一行一个，`#` 开头的是注释；匹配时忽略大小写和空白。
pub struct KeywordFilter {
    words: Vec<String>,
}

fn normalize(s: &str) -> String {
    s.chars()
        .filter(|c| !c.is_whitespace())
        .flat_map(char::to_lowercase)
        .collect()
}

impl KeywordFilter {
    pub fn new<I: IntoIterator<Item = S>, S: AsRef<str>>(words: I) -> Self {
        let words = words
            .into_iter()
            .map(|w| normalize(w.as_ref()))
            .filter(|w| !w.is_empty() && !w.starts_with('#'))
            .collect();
        Self { words }
    }

    pub fn load(path: &Path) -> std::io::Result<Self> {
        let text = std::fs::read_to_string(path)?;
        Ok(Self::new(text.lines()))
    }

    pub fn len(&self) -> usize {
        self.words.len()
    }

    pub fn is_empty(&self) -> bool {
        self.words.is_empty()
    }
}

impl ContentFilter for KeywordFilter {
    fn check(&self, text: &str) -> Verdict {
        let t = normalize(text);
        match self.words.iter().position(|w| t.contains(w.as_str())) {
            Some(i) => Verdict::Block {
                reason: format!("keyword #{i}"),
            },
            None => Verdict::Pass,
        }
    }
}

/// 命中时系统通知里显示的正文。
pub const BLOCKED_BODY: &str = "有新的结果，打开 App 查看";

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn keywords_match_loosely_and_skip_comments() {
        let f = KeywordFilter::new(["# 注释", "坏词", "Bad Word", ""]);
        assert_eq!(f.len(), 2);
        assert_eq!(f.check("一切正常"), Verdict::Pass);
        assert!(matches!(f.check("这里有 坏 词"), Verdict::Block { .. }));
        assert!(matches!(f.check("a BADWORD here"), Verdict::Block { .. }));
        assert_eq!(AllowAll.check("坏词"), Verdict::Pass);
    }
}
