//! Everything that exercises the Tornado tools and the private borrow, as one test target (one
//! link, one `common`). Each module is what used to be its own file:
//! - `shield`: shield, unshield and prepare_shield through the agent and the review.
//! - `held_notes`: the held-notes check against the pinned edw.
//! - `borrow`: the private borrow through the card and the pinned edw.
//! - `skill`: the shipped `private-aave-borrow` skill.
//! - `fork`: the whole borrow on a Sepolia fork (ignored).
//! - `live`: the borrow through the real TUI on Sepolia (ignored).

#[path = "../common/mod.rs"]
mod common;

mod borrow;
mod fork;
mod held_notes;
mod live;
mod shield;
mod skill;
