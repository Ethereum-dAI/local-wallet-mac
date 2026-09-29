//! Rendering. Chat on the left, the `edw` command log on the right, input and status below,
//! and a modal when a command waits for confirmation.

use ratatui::{
    Frame,
    layout::{Constraint, Layout, Rect},
    style::{Color, Modifier, Style, Stylize},
    text::{Line, Span, Text},
    widgets::{Block, Borders, Clear, Paragraph, Wrap},
};

use crate::app::{App, ChatLine, LogEntry};

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
    let [chat, log] =
        Layout::horizontal([Constraint::Percentage(55), Constraint::Percentage(45)]).areas(main);

    render_bottom_anchored(frame, chat, chat_text(app), " Chat ");
    render_bottom_anchored(frame, log, log_text(app), " edw commands ");

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

    let hint = if !app.pending.is_empty() {
        "y run · n cancel"
    } else {
        "Enter send · /models · Esc clear · Ctrl-C quit"
    };
    frame.render_widget(
        Paragraph::new(format!(
            " model {} · data {} · {hint}",
            app.model, app.data_dir
        ))
        .style(Style::new().reversed()),
        status,
    );

    if let Some(pending) = app.pending.front() {
        render_confirm(frame, &pending.command, app.pending.len());
    }
}

/// Keeps the newest lines visible: scrolls so the text ends at the bottom of the panel.
fn render_bottom_anchored(frame: &mut Frame, area: Rect, text: Text<'static>, title: &'static str) {
    let paragraph = Paragraph::new(text)
        .wrap(Wrap { trim: false })
        .block(Block::bordered().title(title));
    let inner_height = area.height.saturating_sub(2) as usize;
    let lines = paragraph
        .line_count(area.width.saturating_sub(2))
        .saturating_sub(2);
    let offset = lines.saturating_sub(inner_height).min(u16::MAX as usize) as u16;
    frame.render_widget(paragraph.scroll((offset, 0)), area);
}

fn chat_text(app: &App) -> Text<'static> {
    if app.chat.is_empty() {
        return Text::from(vec![
            Line::from("Ask in plain language, e.g.".dark_gray()),
            Line::from("  unlock sepolia · show my profiles · add a profile named bob".dark_gray()),
            Line::from("edw cannot transfer yet.".dark_gray()),
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

fn render_confirm(frame: &mut Frame, command: &str, queued: usize) {
    let area = frame.area();
    let width = (command.chars().count() as u16 + 8).clamp(40, area.width.saturating_sub(4));
    let [popup] = Layout::horizontal([Constraint::Length(width)])
        .flex(ratatui::layout::Flex::Center)
        .areas(area);
    let [popup] = Layout::vertical([Constraint::Length(7)])
        .flex(ratatui::layout::Flex::Center)
        .areas(popup);
    let text = Text::from(vec![
        Line::default(),
        Line::from(format!("  {command}")).add_modifier(Modifier::BOLD),
        Line::default(),
        Line::from(vec![
            "  [y] ".green().bold(),
            "run   ".into(),
            "[n] ".red().bold(),
            "cancel".into(),
        ]),
    ]);
    frame.render_widget(Clear, popup);
    frame.render_widget(
        Paragraph::new(text).block(
            Block::new()
                .borders(Borders::ALL)
                .title(if queued > 1 {
                    format!(" Run this command? (1 of {queued}) ")
                } else {
                    " Run this command? ".to_owned()
                })
                .yellow(),
        ),
        popup,
    );
}

#[cfg(test)]
mod tests {
    use ratatui::{Terminal, backend::TestBackend};
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
}
