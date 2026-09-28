use ratatui::layout::{Constraint, Direction, Layout, Rect};
use ratatui::style::{Color, Modifier, Style};
use ratatui::text::{Line, Span};
use ratatui::widgets::{Block, Borders, Clear, List, ListItem, ListState, Paragraph, Wrap};
use ratatui::Frame;

use crate::app::{App, Column, EditorField, EditorMode, EditorState};
use crate::text::{sanitize_editor_text, sanitize_terminal_text};

pub fn draw(frame: &mut Frame<'_>, app: &App, repository: &str) {
    let areas = Layout::default()
        .direction(Direction::Vertical)
        .constraints([
            Constraint::Length(1),
            Constraint::Min(6),
            Constraint::Length(4),
            Constraint::Length(if app.show_help { 3 } else { 1 }),
        ])
        .split(frame.area());

    frame.render_widget(
        Paragraph::new(format!(
            "Gitea Kanban — {} — {}",
            sanitize_terminal_text(repository),
            sanitize_terminal_text(&app.board_title)
        ))
        .style(
            Style::default()
                .fg(Color::Cyan)
                .add_modifier(Modifier::BOLD),
        ),
        areas[0],
    );
    draw_columns(frame, app, areas[1]);
    draw_detail(frame, app, areas[2]);

    let help = if app.show_help {
        format!(
            "{}\n←/h →/l: column  ↑/k ↓/j: card  H/L: move  n: new  e: edit  d: delete  r: refresh  ?: help  q: quit",
            sanitize_terminal_text(&app.status)
        )
    } else {
        format!(
            "{}  |  ?: help  q: quit",
            sanitize_terminal_text(&app.status)
        )
    };
    frame.render_widget(Paragraph::new(help).wrap(Wrap { trim: true }), areas[3]);
    if let Some(editor) = &app.editor {
        draw_editor(frame, editor);
    }
}

fn draw_editor(frame: &mut Frame<'_>, editor: &EditorState) {
    let area = centered_rect(frame.area(), 80, 45);
    frame.render_widget(Clear, area);
    let (title, content) = match &editor.mode {
        EditorMode::Delete {
            issue_number,
            title,
        } => (
            "Delete issue".to_owned(),
            format!(
                "Delete issue #{issue_number} — {}?\n\n[y] confirm  [n/Esc] cancel",
                sanitize_terminal_text(title)
            ),
        ),
        EditorMode::Create { .. } => (
            "New issue".to_owned(),
            editor_content(editor, "Create issue"),
        ),
        EditorMode::Edit { issue_number } => (
            format!("Edit issue #{issue_number}"),
            editor_content(editor, "Edit issue"),
        ),
    };
    frame.render_widget(
        Paragraph::new(content)
            .block(
                Block::default()
                    .title(format!(" {title} "))
                    .borders(Borders::ALL),
            )
            .wrap(Wrap { trim: false }),
        area,
    );
}

fn editor_content(editor: &EditorState, action: &str) -> String {
    let title_marker = if editor.field == EditorField::Title {
        "▶ "
    } else {
        "  "
    };
    let body_marker = if editor.field == EditorField::Body {
        "▶ "
    } else {
        "  "
    };
    format!(
        "{title_marker}Title: {}\n{body_marker}Body: {}\n\nTab: switch field  Enter: title → body  Ctrl-S: save  Esc: cancel\n{action}",
        sanitize_terminal_text(&editor.title),
        sanitize_editor_text(&editor.body)
    )
}

fn centered_rect(area: Rect, width_percent: u16, height_percent: u16) -> Rect {
    let vertical = Layout::default()
        .direction(Direction::Vertical)
        .constraints([
            Constraint::Percentage((100 - height_percent) / 2),
            Constraint::Percentage(height_percent),
            Constraint::Percentage((100 - height_percent) / 2),
        ])
        .split(area);
    Layout::default()
        .direction(Direction::Horizontal)
        .constraints([
            Constraint::Percentage((100 - width_percent) / 2),
            Constraint::Percentage(width_percent),
            Constraint::Percentage((100 - width_percent) / 2),
        ])
        .split(vertical[1])[1]
}

fn draw_columns(frame: &mut Frame<'_>, app: &App, area: Rect) {
    let widths = vec![Constraint::Ratio(1, app.columns.len() as u32); app.columns.len()];
    let areas = Layout::default()
        .direction(Direction::Horizontal)
        .constraints(widths)
        .split(area);

    for (index, column) in app.columns.iter().enumerate() {
        draw_column(frame, app, column, index, areas[index]);
    }
}

fn draw_column(frame: &mut Frame<'_>, app: &App, column: &Column, index: usize, area: Rect) {
    let focused = index == app.focused_column;
    let border_style = if focused {
        Style::default().fg(Color::Yellow)
    } else {
        Style::default()
    };
    let items: Vec<ListItem<'_>> = column
        .cards
        .iter()
        .map(|issue| {
            ListItem::new(Line::from(vec![
                Span::styled(
                    format!("#{} ", issue.number),
                    Style::default().fg(Color::DarkGray),
                ),
                Span::raw(sanitize_terminal_text(&issue.title)),
            ]))
        })
        .collect();
    let list = List::new(items)
        .block(
            Block::default()
                .title(format!(
                    " {} ({}) ",
                    sanitize_terminal_text(&column.spec.title),
                    column.cards.len()
                ))
                .borders(Borders::ALL)
                .border_style(border_style),
        )
        .highlight_style(
            Style::default()
                .bg(Color::Blue)
                .fg(Color::White)
                .add_modifier(Modifier::BOLD),
        )
        .highlight_symbol("▶ ");
    let mut state = ListState::default();
    if focused && !column.cards.is_empty() {
        state.select(Some(app.focused_cards[index]));
    }
    frame.render_stateful_widget(list, area, &mut state);
}

fn draw_detail(frame: &mut Frame<'_>, app: &App, area: Rect) {
    let text = app
        .focused_card()
        .map(|issue| {
            let body = sanitize_terminal_text(
                &issue
                    .body
                    .as_deref()
                    .unwrap_or("No description")
                    .replace('\n', " "),
            );
            format!(
                "#{} {}\n{}",
                issue.number,
                sanitize_terminal_text(&issue.title),
                body
            )
        })
        .unwrap_or_else(|| "No card in focused column".to_owned());
    frame.render_widget(
        Paragraph::new(text)
            .block(Block::default().title(" Detail ").borders(Borders::ALL))
            .wrap(Wrap { trim: true }),
        area,
    );
}
