//! The card shown in the chat for one action: what triggered it and how far it has got.
//!
//! The agent reports stage changes as [`FlowEvent`]s; [`Flow`] folds them into steps and draws
//! them. Nothing here touches the terminal or the network.

use std::time::{Duration, Instant};

use ratatui::{style::Stylize, text::Line};

/// What started the action.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Trigger {
    /// The user asked for it in chat (a transfer or swap).
    User,
    /// The model ran an action of an installed skill.
    Skill { skill: String, action: String },
}

/// One stage an action goes through. A card lists the stages that apply to its kind.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Stage {
    /// Build the transaction and dry-run it (transfers and swaps).
    Prepare,
    /// The skill's script proposes a plan.
    Script,
    /// The harness checks the plan against the skill's manifest.
    Plan,
    /// The plan is simulated and its preview written.
    Simulate,
    /// The user answers yes or no.
    Review,
    /// The transaction is signed and submitted.
    Send,
}

impl Stage {
    pub const TRANSFER: [Stage; 3] = [Stage::Prepare, Stage::Review, Stage::Send];
    pub const SKILL_ACTION: [Stage; 5] = [
        Stage::Script,
        Stage::Plan,
        Stage::Simulate,
        Stage::Review,
        Stage::Send,
    ];

    fn label(self) -> &'static str {
        match self {
            Stage::Prepare => "prepare",
            Stage::Script => "skill script",
            Stage::Plan => "plan check",
            Stage::Simulate => "simulate",
            Stage::Review => "your review",
            Stage::Send => "send",
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum StepState {
    Pending,
    Running,
    Done,
    Failed,
    Declined,
    /// Never reached, because an earlier step failed or was declined.
    Skipped,
}

/// What the agent tells the UI about an action in flight.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum FlowEvent {
    /// A new action. Every stage starts pending.
    Begin {
        trigger: Trigger,
        title: String,
        stages: Vec<Stage>,
    },
    Step {
        stage: Stage,
        state: StepState,
        detail: Option<String>,
    },
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Step {
    pub stage: Stage,
    pub state: StepState,
    pub detail: Option<String>,
    started: Option<Instant>,
    elapsed: Option<Duration>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Flow {
    pub trigger: Trigger,
    pub title: String,
    /// The message the user typed that led here.
    pub prompt: String,
    pub steps: Vec<Step>,
}

impl Flow {
    pub fn new(trigger: Trigger, title: String, prompt: String, stages: &[Stage]) -> Self {
        Self {
            trigger,
            title,
            prompt,
            steps: stages
                .iter()
                .map(|&stage| Step {
                    stage,
                    state: StepState::Pending,
                    detail: None,
                    started: None,
                    elapsed: None,
                })
                .collect(),
        }
    }

    /// Moves `stage` to `state`. A failed or declined step ends the action: the stages after it
    /// are never reached. A stage this card does not list is ignored.
    pub fn apply(&mut self, stage: Stage, state: StepState, detail: Option<String>, now: Instant) {
        let Some(step) = self.steps.iter_mut().find(|s| s.stage == stage) else {
            return;
        };
        match state {
            StepState::Running => step.started = Some(now),
            StepState::Done | StepState::Failed | StepState::Declined => {
                step.elapsed = step.started.map(|at| now.saturating_duration_since(at));
            }
            StepState::Pending | StepState::Skipped => {}
        }
        step.state = state;
        if detail.is_some() {
            step.detail = detail;
        }
        if matches!(state, StepState::Failed | StepState::Declined) {
            self.abandon();
        }
    }

    /// The running step failed: a command it started reported an error. `false` when nothing
    /// was running.
    pub fn fail_running(&mut self, detail: String, now: Instant) -> bool {
        let Some(stage) = self
            .steps
            .iter()
            .find(|s| s.state == StepState::Running)
            .map(|s| s.stage)
        else {
            return false;
        };
        self.apply(stage, StepState::Failed, Some(detail), now);
        true
    }

    /// Stops waiting for the stages not yet done.
    pub fn abandon(&mut self) {
        for step in &mut self.steps {
            if matches!(step.state, StepState::Pending | StepState::Running) {
                step.state = StepState::Skipped;
            }
        }
    }

    /// Some stage has yet to finish, so the card is still changing.
    pub fn is_active(&self) -> bool {
        self.steps
            .iter()
            .any(|s| matches!(s.state, StepState::Pending | StepState::Running))
    }

    /// The card as chat lines. `spinner` marks the running step.
    pub fn lines(&self, spinner: &str) -> Vec<Line<'static>> {
        let trigger = match &self.trigger {
            Trigger::User => "you".to_owned(),
            Trigger::Skill { skill, action } => format!("skill {skill} › {action}"),
        };
        let mut lines = vec![Line::from(vec!["  trigger  ".cyan(), trigger.into()])];
        if !self.prompt.is_empty() {
            lines.push(Line::from(vec![
                "           ".into(),
                format!("← \"{}\"", clip(&self.prompt, 60)).dark_gray(),
            ]));
        }
        lines.push(Line::from(vec![
            "  action   ".cyan(),
            clip(&self.title, 80).into(),
        ]));
        for step in &self.steps {
            let mark = match step.state {
                StepState::Done => "✓".green(),
                StepState::Running => spinner.to_owned().yellow(),
                StepState::Failed | StepState::Declined => "✗".red(),
                StepState::Pending => "○".dark_gray(),
                StepState::Skipped => "–".dark_gray(),
            };
            let label = format!("{:<13}", step.stage.label());
            let label = match step.state {
                StepState::Pending | StepState::Skipped => label.dark_gray(),
                StepState::Failed | StepState::Declined => label.red(),
                StepState::Running => label.bold(),
                StepState::Done => label.into(),
            };
            let mut tail = Vec::new();
            if let Some(detail) = &step.detail {
                tail.push(clip(detail, 70));
            }
            if let Some(elapsed) = step.elapsed {
                tail.push(duration_text(elapsed));
            }
            let tail = tail.join("  ");
            let tail = match step.state {
                StepState::Failed | StepState::Declined => tail.red(),
                _ => tail.dark_gray(),
            };
            lines.push(Line::from(vec![
                "   ".into(),
                mark,
                " ".into(),
                label,
                " ".into(),
                tail,
            ]));
        }
        lines
    }
}

/// One line, at most `max` characters.
fn clip(text: &str, max: usize) -> String {
    let one_line = text.split_whitespace().collect::<Vec<_>>().join(" ");
    if one_line.chars().count() <= max {
        return one_line;
    }
    let mut clipped: String = one_line.chars().take(max.saturating_sub(1)).collect();
    clipped.push('…');
    clipped
}

fn duration_text(elapsed: Duration) -> String {
    if elapsed < Duration::from_secs(1) {
        format!("{} ms", elapsed.as_millis())
    } else {
        format!("{:.1} s", elapsed.as_secs_f64())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn skill_flow() -> Flow {
        Flow::new(
            Trigger::Skill {
                skill: "aave-v3-lend".into(),
                action: "supply".into(),
            },
            "skill aave-v3-lend/supply".into(),
            "supply 100 USDC on aave".into(),
            &Stage::SKILL_ACTION,
        )
    }

    fn text(flow: &Flow) -> String {
        flow.lines("⠹")
            .iter()
            .map(|line| {
                line.spans
                    .iter()
                    .map(|s| s.content.as_ref())
                    .collect::<String>()
            })
            .collect::<Vec<_>>()
            .join("\n")
    }

    fn states(flow: &Flow) -> Vec<StepState> {
        flow.steps.iter().map(|s| s.state).collect()
    }

    #[test]
    fn a_new_card_lists_every_stage_as_pending() {
        let flow = skill_flow();
        assert_eq!(states(&flow), [StepState::Pending; 5]);
        assert!(flow.is_active());
        let text = text(&flow);
        for needle in [
            "trigger  skill aave-v3-lend › supply",
            "← \"supply 100 USDC on aave\"",
            "action   skill aave-v3-lend/supply",
            "○ skill script",
            "○ send",
        ] {
            assert!(text.contains(needle), "missing {needle:?} in\n{text}");
        }
    }

    #[test]
    fn a_user_trigger_is_named_you() {
        let flow = Flow::new(
            Trigger::User,
            "transfer 0.1 ETH to bob".into(),
            String::new(),
            &Stage::TRANSFER,
        );
        let text = text(&flow);
        assert!(text.contains("trigger  you"), "{text}");
        assert!(!text.contains('←'), "no prompt, no prompt line: {text}");
    }

    #[test]
    fn a_stage_reports_how_long_it_took() {
        let t0 = Instant::now();
        let mut flow = skill_flow();
        flow.apply(Stage::Script, StepState::Running, None, t0);
        flow.apply(
            Stage::Script,
            StepState::Done,
            None,
            t0 + Duration::from_millis(800),
        );
        let text = text(&flow);
        assert!(text.contains("✓ skill script"), "{text}");
        assert!(text.contains("800 ms"), "{text}");
    }

    #[test]
    fn seconds_are_shown_past_one_second() {
        assert_eq!(duration_text(Duration::from_millis(999)), "999 ms");
        assert_eq!(duration_text(Duration::from_millis(1240)), "1.2 s");
    }

    #[test]
    fn the_running_stage_shows_the_spinner() {
        let mut flow = skill_flow();
        flow.apply(Stage::Script, StepState::Running, None, Instant::now());
        assert!(text(&flow).contains("⠹ skill script"));
    }

    #[test]
    fn a_declined_review_skips_what_follows() {
        let mut flow = skill_flow();
        let now = Instant::now();
        for stage in [Stage::Script, Stage::Plan, Stage::Simulate] {
            flow.apply(stage, StepState::Done, None, now);
        }
        flow.apply(Stage::Review, StepState::Running, None, now);
        flow.apply(
            Stage::Review,
            StepState::Declined,
            Some("declined".into()),
            now,
        );
        assert_eq!(
            states(&flow),
            [
                StepState::Done,
                StepState::Done,
                StepState::Done,
                StepState::Declined,
                StepState::Skipped,
            ]
        );
        assert!(!flow.is_active());
        assert!(text(&flow).contains("✗ your review"));
    }

    #[test]
    fn a_failure_marks_the_running_stage_and_skips_the_rest() {
        let now = Instant::now();
        let mut flow = skill_flow();
        flow.apply(Stage::Script, StepState::Done, None, now);
        flow.apply(Stage::Plan, StepState::Running, None, now);
        assert!(flow.fail_running("the plan was refused (no approve)".into(), now));
        assert_eq!(
            states(&flow),
            [
                StepState::Done,
                StepState::Failed,
                StepState::Skipped,
                StepState::Skipped,
                StepState::Skipped,
            ]
        );
        assert!(text(&flow).contains("the plan was refused (no approve)"));
    }

    #[test]
    fn a_failure_with_nothing_running_changes_nothing() {
        let mut flow = skill_flow();
        let before = flow.clone();
        assert!(!flow.fail_running("boom".into(), Instant::now()));
        assert_eq!(flow, before);
    }

    #[test]
    fn a_stage_the_card_does_not_list_is_ignored() {
        let mut flow = Flow::new(
            Trigger::User,
            "transfer".into(),
            String::new(),
            &Stage::TRANSFER,
        );
        let before = flow.clone();
        flow.apply(Stage::Plan, StepState::Done, None, Instant::now());
        assert_eq!(flow, before);
    }

    #[test]
    fn a_finished_card_is_not_active() {
        let now = Instant::now();
        let mut flow = Flow::new(
            Trigger::User,
            "transfer".into(),
            String::new(),
            &Stage::TRANSFER,
        );
        for stage in Stage::TRANSFER {
            flow.apply(stage, StepState::Done, None, now);
        }
        assert!(!flow.is_active());
    }

    #[test]
    fn long_titles_and_prompts_are_clipped_to_one_line() {
        let flow = Flow::new(
            Trigger::User,
            format!("send {}", "x".repeat(200)),
            "line one\nline two".into(),
            &Stage::TRANSFER,
        );
        let text = text(&flow);
        assert!(text.contains("← \"line one line two\""), "{text}");
        let action = text.lines().find(|l| l.contains("action")).unwrap();
        assert!(action.chars().count() < 100, "{action}");
        assert!(action.ends_with('…'));
    }
}
