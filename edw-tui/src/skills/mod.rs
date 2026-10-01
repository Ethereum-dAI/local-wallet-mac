//! Skills: folders the agent loads on demand. See `docs/` and the README section "Skills".

pub mod abi;
pub mod catalog;
pub mod lock;
pub mod manifest;

/// The one built-in skill tool: loads a skill (and what it requires) for the conversation.
pub const LOAD_SKILL: &str = "load_skill";
pub mod host;
pub mod sandbox;
