//! Rendering. Chat on the left, the `edw` command log on the right, input and status below,
//! and a modal when a command waits for confirmation.

use ratatui::{
    Frame,
    layout::{Constraint, Layout, Rect},
    style::{Color, Modifier, Style, Stylize},
    text::{Line, Span, Text},
    widgets::{Block, Borders, Clear, Paragraph, Wrap},
};

use crate::{
    app::{App, ChatLine, LogEntry, PanelScroll, PendingConfirm, View},
    skills::consent::ConsentRequest,
};

/// The input grows with its text up to this many rows, then scrolls to keep the end visible.
const MAX_INPUT_ROWS: usize = 6;
const PROMPT: &str = "> ";

/// Hard-wraps `text` into rows of exactly `width` characters, so the cursor position is known.
/// A trailing full row gets an empty row after it, which is where the cursor goes next.
fn wrap_input(text: &str, width: usize) -> Vec<String> {
    let chars: Vec<char> = text.chars().collect();
    let width = width.max(1);
    let mut rows: Vec<String> = chars.chunks(width).map(|c| c.iter().collect()).collect();
    if chars.len().is_multiple_of(width) {
        rows.push(String::new());
    }
    rows
}

pub fn render(frame: &mut Frame, app: &App) {
    let inner_width = frame.area().width.saturating_sub(2) as usize;
    let rows = wrap_input(&format!("{PROMPT}{}", app.input), inner_width);
    let visible = rows.len().min(MAX_INPUT_ROWS);

    let [main, input, status] = Layout::vertical([
        Constraint::Min(5),
        Constraint::Length(visible as u16 + 2),
        Constraint::Length(1),
    ])
    .areas(frame.area());
    match app.view {
        View::Split => {
            let [chat, log] =
                Layout::horizontal([Constraint::Percentage(55), Constraint::Percentage(45)])
                    .areas(main);
            render_bottom_anchored(
                frame,
                chat,
                chat_text(app),
                " Chat ",
                Borders::ALL,
                &app.chat_scroll,
            );
            render_bottom_anchored(
                frame,
                log,
                log_text(app),
                " edw commands ",
                Borders::ALL,
                &app.log_scroll,
            );
        }
        // One panel, full width, with no side borders: a terminal selection then copies only
        // this panel's text.
        View::Chat => render_bottom_anchored(
            frame,
            main,
            chat_text(app),
            " Chat · Tab: commands ",
            Borders::TOP,
            &app.chat_scroll,
        ),
        View::Log => render_bottom_anchored(
            frame,
            main,
            log_text(app),
            " edw commands · Tab: both ",
            Borders::TOP,
            &app.log_scroll,
        ),
    }

    let prompt: Text = if app.busy {
        "thinking…".dark_gray().into()
    } else {
        let shown = &rows[rows.len() - visible..];
        let mut lines: Vec<Line> = shown.iter().map(|row| Line::from(row.clone())).collect();
        // Bold the prompt marker when the first row is on screen.
        if visible == rows.len()
            && let Some(first) = lines.first_mut()
        {
            let rest = shown[0].chars().skip(PROMPT.len()).collect::<String>();
            *first = Line::from(vec![PROMPT.bold(), rest.into()]);
        }
        Text::from(lines)
    };
    frame.render_widget(
        Paragraph::new(prompt).block(Block::bordered().title(" Message ")),
        input,
    );
    if !app.busy && app.pending.is_empty() {
        let last = rows.last().map_or(0, |row| row.chars().count()) as u16;
        frame.set_cursor_position((input.x + 1 + last, input.y + visible as u16));
    }

    let hint = if !app.consents.is_empty() {
        "y allow · n decline · ↑↓ scroll"
    } else if !app.pending.is_empty() {
        "y run · n cancel"
    } else if app.busy && app.skills.is_empty() {
        "Preparing skills…"
    } else {
        "Enter send · Tab one panel · /copy · /help · Ctrl-C quit"
    };
    frame.render_widget(
        Paragraph::new(format!(
            " model {} · from {} · data {} · {hint}",
            app.model, app.profile, app.data_dir
        ))
        .style(Style::new().reversed()),
        status,
    );

    if let Some(request) = app.consents.front() {
        let index = app.consent_total.saturating_sub(app.consents.len()) + 1;
        render_consent(frame, request, index, app.consent_total, app.consent_scroll);
    } else if let Some(pending) = app.pending.front() {
        render_confirm(frame, pending, app.pending.len());
    }
}

/// The approval card for one skill: what it is, then everything it could touch, by chain.
/// The body scrolls; the title and the keys stay put.
fn render_consent(
    frame: &mut Frame,
    request: &ConsentRequest,
    index: usize,
    total: usize,
    scroll: u16,
) {
    let heading = |text: &'static str| Span::from(text).cyan().bold();
    let field =
        |name: &'static str, value: String| Line::from(vec![heading(name), Span::from(value)]);
    let none_or = |items: &[String], sep: &str, none: &str| {
        if items.is_empty() {
            none.to_owned()
        } else {
            items.join(sep)
        }
    };
    let mut lines = vec![
        Line::from(format!(
            "{} {} · {} · sha256 {}",
            request.name, request.version, request.reason, request.short_hash
        ))
        .bold(),
        Line::from(request.description.clone()),
        Line::default(),
        field(
            "NEEDS      ",
            none_or(&request.requires, ", ", "no other skill"),
        ),
        field(
            "WEB        ",
            none_or(
                &request.hosts,
                ", ",
                if request.tools.is_empty() {
                    "none"
                } else {
                    "none (reads the chain through your RPC)"
                },
            ),
        ),
        field(
            "TOOLS      ",
            none_or(&request.tools, " · ", "none (instructions only)"),
        ),
        Line::default(),
    ];
    if request.chains.is_empty() {
        lines.push(Line::from(vec![
            heading("CAN PROPOSE CALLS TO "),
            Span::from("nothing (read-only)"),
        ]));
    } else {
        lines.push(Line::from(heading("CAN PROPOSE CALLS TO")));
        for chain in &request.chains {
            lines.push(Line::from(format!(" {}", chain.name)).bold());
            for (label, address, functions) in &chain.calls {
                lines.push(Line::from(vec![
                    Span::from(format!("   {label} {address}  ")),
                    Span::from(functions.join(", ")).yellow(),
                ]));
            }
            for approval in &chain.approvals {
                lines.push(Line::from(format!("   approve: {approval}")));
            }
        }
    }
    lines.push(Line::default());
    lines.push(
        Line::from("Every plan is still simulated and reviewed before you send it.").italic(),
    );

    let area = frame.area();
    let width = area.width.saturating_sub(4).min(100);
    let height = (lines.len() as u16 + 4).min(area.height.saturating_sub(2));
    let [popup] = Layout::horizontal([Constraint::Length(width)])
        .flex(ratatui::layout::Flex::Center)
        .areas(area);
    let [popup] = Layout::vertical([Constraint::Length(height)])
        .flex(ratatui::layout::Flex::Center)
        .areas(popup);
    let title = if total > 1 {
        format!(" Allow skill {}? ({index} of {total}) ", request.name)
    } else {
        format!(" Allow skill {}? ", request.name)
    };
    let block = Block::new().borders(Borders::ALL).title(title).yellow();
    let inner = block.inner(popup);
    frame.render_widget(Clear, popup);
    frame.render_widget(block, popup);
    let [body, keys] = Layout::vertical([Constraint::Min(1), Constraint::Length(1)]).areas(
        inner.inner(ratatui::layout::Margin {
            horizontal: 1,
            vertical: 0,
        }),
    );
    let max_scroll = (lines.len() as u16).saturating_sub(body.height);
    frame.render_widget(
        Paragraph::new(Text::from(lines))
            .reset()
            .scroll((scroll.min(max_scroll), 0)),
        body,
    );
    let mut key_line = vec![
        "  [y] ".green().bold(),
        "allow   ".into(),
        "[n] ".red().bold(),
        "decline".into(),
    ];
    if max_scroll > 0 {
        key_line.push("        ↑↓ scroll".dark_gray());
    }
    frame.render_widget(Paragraph::new(Line::from(key_line)).reset(), keys);
}

/// Keeps the newest lines visible: scrolls so the text ends at the bottom of the panel.
fn render_bottom_anchored(
    frame: &mut Frame,
    area: Rect,
    text: Text<'static>,
    title: &'static str,
    borders: Borders,
    scroll: &PanelScroll,
) {
    let count = |sides: Borders| borders.intersection(sides).iter().count() as u16;
    let (vertical, horizontal) = (
        count(Borders::TOP | Borders::BOTTOM),
        count(Borders::LEFT | Borders::RIGHT),
    );
    let wrapped = Paragraph::new(text).wrap(Wrap { trim: false });
    let inner_height = area.height.saturating_sub(vertical) as usize;
    let lines = wrapped.line_count(area.width.saturating_sub(horizontal));
    let top = scroll.observe(lines, inner_height);
    // Scrolled back: say so, and how to get to the newest lines.
    let title = if scroll.following() || lines <= inner_height {
        title.to_owned()
    } else {
        format!("{title}↑ older · PgDn/End ")
    };
    let paragraph = wrapped.block(Block::new().borders(borders).title(title));
    let offset = top.min(u16::MAX as usize) as u16;
    frame.render_widget(paragraph.scroll((offset, 0)), area);
}

fn chat_text(app: &App) -> Text<'static> {
    if app.chat.is_empty() {
        return Text::from(vec![
            Line::from("Ask in plain language, e.g.".dark_gray()),
            Line::from("  unlock sepolia · show my profiles · add a profile named bob".dark_gray()),
            Line::from("  balance · send 0.1 ETH to 0x… (you review every transfer)".dark_gray()),
            Line::from("Switch LLM: /models, then /model <number>.".dark_gray()),
        ]);
    }
    let mut lines = Vec::new();
    for entry in &app.chat {
        let (label, style, text) = match entry {
            ChatLine::User(t) => ("you", Style::new().fg(Color::Cyan).bold(), t),
            ChatLine::Assistant(t) => ("edw", Style::new().fg(Color::Green).bold(), t),
            ChatLine::Error(t) => ("error", Style::new().fg(Color::Red).bold(), t),
            ChatLine::Info(t) => ("info", Style::new().fg(Color::Yellow).bold(), t),
        };
        let mut body = text.lines();
        lines.push(Line::from(vec![
            Span::styled(format!("{label}: "), style),
            body.next().unwrap_or("").to_owned().into(),
        ]));
        lines.extend(body.map(|l| Line::from(format!("  {l}"))));
        lines.push(Line::default());
    }
    Text::from(lines)
}

fn log_text(app: &App) -> Text<'static> {
    let mut lines = Vec::new();
    for entry in &app.log {
        match entry {
            LogEntry::Running(command) => lines.push(Line::from(vec![
                "… ".yellow(),
                format!("$ {command}").bold(),
            ])),
            LogEntry::Declined(command) => lines.push(Line::from(vec![
                "✗ ".red(),
                format!("$ {command}").crossed_out(),
                "  declined".red(),
            ])),
            LogEntry::Finished(result) => {
                let mark = if result.ok() {
                    "✓ ".green()
                } else {
                    format!("✗ exit {} ", result.exit_code).red()
                };
                lines.push(Line::from(vec![
                    mark,
                    format!("$ {}", result.command).bold(),
                ]));
                lines.extend(
                    result
                        .output
                        .lines()
                        .map(|l| Line::from(format!("  {l}")).dark_gray()),
                );
            }
        }
        lines.push(Line::default());
    }
    Text::from(lines)
}

fn render_confirm(frame: &mut Frame, pending: &PendingConfirm, queued: usize) {
    let area = frame.area();
    let preview: Vec<&str> = pending
        .preview
        .as_deref()
        .map_or_else(Vec::new, |p| p.lines().collect());
    let widest = preview
        .iter()
        .map(|l| l.chars().count())
        .chain([pending.command.chars().count()])
        .max()
        .unwrap_or(0);
    let width = (widest as u16 + 8).clamp(40, area.width.saturating_sub(4));
    let extra = if preview.is_empty() {
        0
    } else {
        preview.len() + 1
    };
    let [popup] = Layout::horizontal([Constraint::Length(width)])
        .flex(ratatui::layout::Flex::Center)
        .areas(area);
    let [popup] = Layout::vertical([Constraint::Length(7 + extra as u16)])
        .flex(ratatui::layout::Flex::Center)
        .areas(popup);
    let mut lines = vec![Line::default()];
    for line in &preview {
        lines.push(Line::from(format!("  {line}")));
    }
    if !preview.is_empty() {
        lines.push(Line::default());
    }
    lines.push(Line::from(format!("  {}", pending.command)).add_modifier(Modifier::BOLD));
    lines.push(Line::default());
    let (yes, title) = if preview.is_empty() {
        ("run   ", "Run this command?")
    } else {
        ("send  ", "Send this transaction?")
    };
    lines.push(Line::from(vec![
        "  [y] ".green().bold(),
        yes.into(),
        "[n] ".red().bold(),
        "cancel".into(),
    ]));
    frame.render_widget(Clear, popup);
    frame.render_widget(
        Paragraph::new(Text::from(lines)).block(
            Block::new()
                .borders(Borders::ALL)
                .title(if queued > 1 {
                    format!(" {title} (1 of {queued}) ")
                } else {
                    format!(" {title} ")
                })
                .yellow(),
        ),
        popup,
    );
}

#[cfg(test)]
mod tests {
    use ratatui::{
        Terminal,
        backend::TestBackend,
        crossterm::event::{KeyCode, KeyEvent, KeyModifiers},
    };
    use tokio::sync::oneshot;

    use super::*;
    use crate::{agent::AgentEvent, edw::EdwResult};

    fn screen(app: &App) -> String {
        let mut terminal = Terminal::new(TestBackend::new(100, 24)).unwrap();
        terminal.draw(|frame| render(frame, app)).unwrap();
        let buffer = terminal.backend().buffer();
        (0..buffer.area.height)
            .map(|y| {
                (0..buffer.area.width)
                    .map(|x| buffer[(x, y)].symbol())
                    .collect::<String>()
            })
            .collect::<Vec<_>>()
            .join("\n")
    }

    #[test]
    fn shows_chat_log_and_status() {
        let mut app = App::new("gemma4:latest", ".edw/data");
        app.chat.push(ChatLine::User("show my profiles".into()));
        app.on_agent(AgentEvent::ToolFinished(EdwResult {
            command: "edw profile list".into(),
            exit_code: 0,
            output: "Mnemonic 0\n  0  default".into(),
        }));
        app.on_agent(AgentEvent::Reply("You have one profile, default.".into()));
        let screen = screen(&app);
        for needle in [
            "you: show my profiles",
            "edw: You have one profile, default.",
            "✓ $ edw profile list",
            "0  default",
            "model gemma4:latest",
        ] {
            assert!(screen.contains(needle), "missing {needle:?} in\n{screen}");
        }
    }

    #[test]
    fn shows_the_confirmation_modal() {
        let mut app = App::new("m", "d");
        let (reply, _answer) = oneshot::channel();
        app.on_agent(AgentEvent::Confirm {
            command: "edw unlock --network sepolia".into(),
            preview: None,
            reply,
        });
        let screen = screen(&app);
        for needle in [
            "Run this command?",
            "edw unlock --network sepolia",
            "[y] run",
            "[n] cancel",
            "y run · n cancel",
        ] {
            assert!(screen.contains(needle), "missing {needle:?} in\n{screen}");
        }
    }

    fn aave_request() -> crate::skills::consent::ConsentRequest {
        use crate::skills::{consent::*, lock::hash_dir, manifest};
        let dir = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("skills/aave-v3-lend");
        let skill = manifest::load(&dir).unwrap();
        ConsentRequest::new(&skill, &hash_dir(&skill.dir).unwrap(), Reason::New)
    }

    fn tall_screen(app: &App, rows: u16) -> String {
        let mut terminal = Terminal::new(TestBackend::new(100, rows)).unwrap();
        terminal.draw(|frame| render(frame, app)).unwrap();
        let buffer = terminal.backend().buffer();
        (0..buffer.area.height)
            .map(|y| {
                (0..buffer.area.width)
                    .map(|x| buffer[(x, y)].symbol())
                    .collect::<String>()
            })
            .collect::<Vec<_>>()
            .join("\n")
    }

    #[test]
    fn shows_a_skill_approval_card_grouped_by_what_it_can_touch() {
        let mut app = App::new("m", "d");
        let request = aave_request();
        let hash = request.short_hash.clone();
        app.ask_consents(vec![request, aave_request()]);
        let screen = tall_screen(&app, 40);
        for needle in [
            "Allow skill aave-v3-lend? (1 of 2)",
            &format!("aave-v3-lend 0.1.0 · new · sha256 {hash}"),
            "Earn interest on idle USDC",
            "NEEDS",
            "defi-data",
            "WEB",
            "none (reads the chain through your RPC)",
            "TOOLS",
            "aave_markets · aave_supply · aave_withdraw",
            "CAN PROPOSE CALLS TO",
            "Ethereum (1)",
            "Aave Pool 0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2",
            "supply, withdraw",
            "approve: USDC, USDT, DAI → Aave Pool (exact amounts)",
            "Sepolia (11155111)",
            "Every plan is still simulated and reviewed before you send it.",
            "[y] allow",
            "[n] decline",
            "y allow · n decline · ↑↓ scroll",
        ] {
            assert!(screen.contains(needle), "missing {needle:?} in\n{screen}");
        }
    }

    #[test]
    fn a_long_approval_card_scrolls_and_keeps_its_keys_visible() {
        let mut app = App::new("m", "d");
        app.ask_consents(vec![aave_request()]);
        let short = tall_screen(&app, 12);
        assert!(short.contains("[y] allow"), "keys always visible:\n{short}");
        assert!(!short.contains("Sepolia (11155111)"), "{short}");
        app.consent_scroll = 30;
        let scrolled = tall_screen(&app, 12);
        assert!(scrolled.contains("Sepolia (11155111)"), "{scrolled}");
        assert!(scrolled.contains("[y] allow"), "{scrolled}");
    }

    #[test]
    fn a_scrolled_panel_shows_older_lines_and_stays_put_when_more_arrive() {
        let mut app = App::new("m", "d");
        for n in 0..60 {
            app.chat.push(ChatLine::Info(format!("message {n:02}")));
        }
        let first = screen(&app);
        assert!(first.contains("message 59") && !first.contains("message 10"));

        app.on_key(KeyEvent::new(KeyCode::PageUp, KeyModifiers::NONE));
        app.on_key(KeyEvent::new(KeyCode::PageUp, KeyModifiers::NONE));
        let scrolled = screen(&app);
        assert!(!scrolled.contains("message 59"), "{scrolled}");
        assert!(scrolled.contains("↑ older · PgDn/End"), "{scrolled}");
        let oldest_shown = (0..60)
            .find(|n| scrolled.contains(&format!("message {n:02}")))
            .unwrap();

        // A new message does not move a scrolled panel.
        app.chat.push(ChatLine::Info("message 60".into()));
        let after = screen(&app);
        assert!(
            after.contains(&format!("message {oldest_shown:02}")),
            "{after}"
        );
        assert!(!after.contains("message 60"), "{after}");

        app.on_key(KeyEvent::new(KeyCode::End, KeyModifiers::NONE));
        let end = screen(&app);
        assert!(
            end.contains("message 60") && !end.contains("↑ older"),
            "{end}"
        );
    }

    #[test]
    fn long_input_wraps_instead_of_running_off_the_edge() {
        let mut app = App::new("m", "d");
        app.input = "unlock the local network, then create a new profile named alice and one named bob, then list".into();
        let screen = screen(&app);
        // 100 columns wide: the text continues on the next row of the input box.
        assert!(screen.contains("> unlock the local network"), "{screen}");
        assert!(screen.contains("then list"), "{screen}");
        let tail = wrap_input(&format!("> {}", app.input), 98);
        assert_eq!(tail.len(), 1 + (app.input.len() + 2) / 98);
    }

    #[test]
    fn wrap_input_rows_have_the_exact_width() {
        assert_eq!(wrap_input("abcdef", 3), ["abc", "def", ""]);
        assert_eq!(wrap_input("abcd", 3), ["abc", "d"]);
        assert_eq!(wrap_input("", 3), [""]);
    }

    #[test]
    fn newest_log_lines_stay_visible() {
        let mut app = App::new("m", "d");
        for i in 0..40 {
            app.on_agent(AgentEvent::ToolFinished(EdwResult {
                command: format!("edw lock #{i}"),
                exit_code: 0,
                output: String::new(),
            }));
        }
        let screen = screen(&app);
        assert!(
            screen.contains("edw lock #39") && !screen.contains("edw lock #0 "),
            "{screen}"
        );
    }

    #[test]
    fn a_single_panel_view_has_no_side_borders_to_copy() {
        let mut app = App::new("m", "d");
        app.chat
            .push(ChatLine::Assistant("You have 10 ETH.".into()));
        app.on_agent(AgentEvent::ToolFinished(EdwResult {
            command: "interim balance --from 0/0".into(),
            exit_code: 0,
            output: "10 ETH".into(),
        }));
        app.view = View::Chat;
        let text = screen(&app);
        let row = text
            .lines()
            .find(|l| l.contains("You have 10 ETH."))
            .unwrap();
        assert!(row.starts_with("edw: You have 10 ETH."), "{row:?}");
        assert!(
            !row.contains('│') && !text.contains("interim balance"),
            "{text}"
        );

        app.view = View::Log;
        let text = screen(&app);
        assert!(text.contains("interim balance") && !text.contains("You have 10 ETH."));
    }
}
