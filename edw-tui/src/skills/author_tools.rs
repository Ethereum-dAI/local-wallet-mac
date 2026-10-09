//! The three tools the model gets while `skill-creator` is loaded. They write and check files
//! in the drafts folder and serve reference text. Nothing here installs, trusts or runs a draft.

use serde_json::{Value, json};

use super::{
    author::{self, DraftStore},
    facts::{self, AbiSource},
    manifest,
};

const GUIDE_MANIFEST: &str = include_str!("guides/manifest.md");
const GUIDE_SDK: &str = include_str!("guides/sdk.md");
const GUIDE_EXAMPLE: &str = include_str!("guides/example.md");

/// (name, description, JSON schema) of each authoring tool, as the model sees them.
pub fn specs() -> Vec<(&'static str, &'static str, Value)> {
    vec![
        (
            author::WRITE,
            "Write one file of a skill draft: SKILL.md, skill.toml or scripts/<name>.py. Rewrites the file if it exists.",
            json!({"type": "object", "required": ["name", "path", "content"], "properties": {
                "name": {"type": "string", "description": "Skill name: lowercase letters, digits, dashes."},
                "path": {"type": "string", "description": "SKILL.md, skill.toml or scripts/<file>.py"},
                "content": {"type": "string"}
            }}),
        ),
        (
            author::CHECK,
            "Check a draft: it must load, scripts must exist and parse, contract addresses and functions are compared with verified source. Returns errors and warnings.",
            json!({"type": "object", "required": ["name"], "properties": {
                "name": {"type": "string"}
            }}),
        ),
        (
            author::GUIDE,
            "Read reference text for writing a skill: topic manifest (skill.toml), sdk (script helpers) or example (a complete small skill).",
            json!({"type": "object", "required": ["topic"], "properties": {
                "topic": {"type": "string", "enum": ["manifest", "sdk", "example"]}
            }}),
        ),
    ]
}

/// Runs one authoring tool. Returns an exit code (0 = ok) and the text for the model.
pub async fn call(
    store: &DraftStore,
    source: &impl AbiSource,
    tool: &str,
    args: &Value,
) -> (i32, String) {
    let text = |key: &str| args.get(key).and_then(Value::as_str);
    let name = text("name").unwrap_or_default();
    match tool {
        author::WRITE => {
            let Some(content) = text("content") else {
                return (1, "content is required".into());
            };
            match store.write(name, text("path").unwrap_or_default(), content) {
                Ok(done) => (0, done),
                Err(why) => (1, why),
            }
        }
        author::CHECK => check_draft(store, source, name).await,
        author::GUIDE => match text("topic").unwrap_or_default() {
            "manifest" => (0, GUIDE_MANIFEST.to_owned()),
            "sdk" => (0, GUIDE_SDK.to_owned()),
            "example" => (0, GUIDE_EXAMPLE.to_owned()),
            other => (
                1,
                format!("there is no guide `{other}`; the topics are manifest, sdk and example"),
            ),
        },
        other => (1, format!("`{other}` is not an authoring tool")),
    }
}

async fn check_draft(store: &DraftStore, source: &impl AbiSource, name: &str) -> (i32, String) {
    let dir = match store.dir(name) {
        Ok(dir) => dir,
        Err(why) => return (1, why),
    };
    if !dir.is_dir() {
        return (
            1,
            format!("there is no draft named {name}; write SKILL.md first"),
        );
    }
    // The check parses scripts with python3, so it runs off the async workers.
    let checked = dir.clone();
    let mut report = tokio::task::spawn_blocking(move || author::check(&checked))
        .await
        .unwrap_or_else(|_| author::Report {
            errors: vec!["the check did not finish".into()],
            ..Default::default()
        });
    if report.ok()
        && let Ok(skill) = manifest::load(&dir)
    {
        if facts::enabled() {
            report.warnings.extend(facts::verify(&skill, source).await);
        } else {
            report.warnings.push(
                "contract addresses were not compared with Sourcify (EDW_TUI_SKILLS_FACTS=off)"
                    .into(),
            );
        }
    }
    let mut out = report.render(name);
    if report.ok() {
        out.push_str(&format!(
            "\nThe draft loads. Tell the user to run `/skill install {name}` to review and allow it; you cannot install it yourself."
        ));
    }
    (i32::from(!report.ok()), out)
}

#[cfg(test)]
mod tests {
    use std::collections::BTreeMap;

    use serde_json::json;

    use super::*;

    struct Offline;

    impl AbiSource for Offline {
        async fn abi(
            &self,
            _: u64,
            _: alloy_primitives::Address,
        ) -> Result<Option<alloy_json_abi::JsonAbi>, String> {
            Err("offline".into())
        }
    }

    fn store() -> (tempfile::TempDir, DraftStore) {
        let root = tempfile::tempdir().unwrap();
        let store = DraftStore::new(root.path().join("drafts"));
        (root, store)
    }

    /// The fenced files under `### FILE: <path>` headings of the example guide.
    fn example_files() -> BTreeMap<String, String> {
        let mut files = BTreeMap::new();
        let mut lines = GUIDE_EXAMPLE.lines();
        while let Some(line) = lines.next() {
            let Some(path) = line.strip_prefix("### FILE: ") else {
                continue;
            };
            assert!(lines.next().unwrap().starts_with("```"));
            let body: Vec<&str> = lines
                .by_ref()
                .take_while(|l| !l.starts_with("```"))
                .collect();
            files.insert(path.to_owned(), format!("{}\n", body.join("\n")));
        }
        files
    }

    #[tokio::test]
    async fn the_example_guide_is_a_draft_that_passes_the_check() {
        let (_root, store) = store();
        let files = example_files();
        assert_eq!(files.len(), 3, "{files:?}");
        for (path, content) in &files {
            let (code, text) = call(
                &store,
                &Offline,
                author::WRITE,
                &json!({"name": "balance-of", "path": path, "content": content}),
            )
            .await;
            assert_eq!(code, 0, "{text}");
        }
        let (code, text) = call(
            &store,
            &Offline,
            author::CHECK,
            &json!({"name": "balance-of"}),
        )
        .await;
        assert_eq!(code, 0, "{text}");
        assert!(text.contains("/skill install balance-of"), "{text}");
    }

    #[tokio::test]
    async fn check_tells_the_model_what_to_fix_and_does_not_offer_to_install() {
        let (_root, store) = store();
        call(
            &store,
            &Offline,
            author::WRITE,
            &json!({"name": "demo", "path": "SKILL.md", "content": "no frontmatter"}),
        )
        .await;
        let (code, text) = call(&store, &Offline, author::CHECK, &json!({"name": "demo"})).await;
        assert_eq!(code, 1);
        assert!(text.contains("Errors"), "{text}");
        assert!(!text.contains("/skill install"), "{text}");
    }

    #[tokio::test]
    async fn bad_arguments_are_refused_with_a_reason() {
        let (_root, store) = store();
        let (code, text) = call(
            &store,
            &Offline,
            author::WRITE,
            &json!({"name": "demo", "path": "SKILL.md"}),
        )
        .await;
        assert_eq!(code, 1);
        assert!(text.contains("content"), "{text}");
        let (code, _) = call(
            &store,
            &Offline,
            author::WRITE,
            &json!({"name": "../x", "path": "SKILL.md", "content": "x"}),
        )
        .await;
        assert_eq!(code, 1);
        let (code, text) = call(
            &store,
            &Offline,
            author::CHECK,
            &json!({"name": "nothing-here"}),
        )
        .await;
        assert_eq!(code, 1);
        assert!(text.contains("no draft"), "{text}");
        let (code, _) = call(&store, &Offline, "skill_install", &json!({})).await;
        assert_eq!(code, 1, "there is no tool that installs");
    }

    #[tokio::test]
    async fn the_guide_serves_each_topic_and_names_the_topics_otherwise() {
        let (_root, store) = store();
        for topic in ["manifest", "sdk", "example"] {
            let (code, text) =
                call(&store, &Offline, author::GUIDE, &json!({"topic": topic})).await;
            assert_eq!(code, 0);
            assert!(
                text.len() > 200 && text.len() < 8 * 1024,
                "{topic}: {}",
                text.len()
            );
        }
        let (code, text) = call(&store, &Offline, author::GUIDE, &json!({"topic": "nope"})).await;
        assert_eq!(code, 1);
        assert!(text.contains("manifest") && text.contains("sdk") && text.contains("example"));
    }

    #[test]
    fn three_tools_are_specified_and_none_installs() {
        let names: Vec<&str> = specs().iter().map(|(n, _, _)| *n).collect();
        assert_eq!(names, author::TOOL_NAMES);
        for (_, description, schema) in specs() {
            assert!(!description.is_empty());
            assert_eq!(schema["type"], "object");
        }
    }
}
