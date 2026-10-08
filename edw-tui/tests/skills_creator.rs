use edw_tui::skills::{author, manifest};

fn creator() -> manifest::Skill {
    manifest::load(std::path::Path::new("skills/skill-creator")).expect("skill-creator loads")
}

#[test]
fn skill_creator_is_shipped_as_instructions_only() {
    let skill = creator();
    assert_eq!(skill.name, author::CREATOR);
    assert!(
        !skill.has_scripts(),
        "tools come from edw-tui, not from the skill"
    );
    assert!(skill.body.len() <= manifest::MAX_BODY);
}

#[test]
fn its_instructions_name_every_authoring_tool_and_the_install_command() {
    let skill = creator();
    for tool in author::TOOL_NAMES {
        assert!(skill.body.contains(tool), "{tool} not mentioned");
    }
    assert!(skill.body.contains("/skill install"));
    assert!(!skill.body.contains("ALWAYS") && !skill.body.contains("NEVER"));
}

#[test]
fn its_description_is_findable_by_what_a_user_would_say() {
    let d = creator().description.to_lowercase();
    for phrase in ["skill", "from this chat", "describe"] {
        assert!(d.contains(phrase), "description lacks `{phrase}`: {d}");
    }
}
