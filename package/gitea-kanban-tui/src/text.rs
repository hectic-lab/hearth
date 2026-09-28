pub fn sanitize_terminal_text(value: &str) -> String {
    value
        .chars()
        .map(|character| {
            if character.is_control() {
                ' '
            } else {
                character
            }
        })
        .collect()
}

pub fn sanitize_editor_text(value: &str) -> String {
    value
        .chars()
        .map(|character| {
            if character == '\n' || !character.is_control() {
                character
            } else {
                ' '
            }
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn strips_terminal_control_characters() {
        assert_eq!(
            sanitize_terminal_text("safe\u{1b}[31m\ntext"),
            "safe [31m text"
        );
    }

    #[test]
    fn editor_sanitizer_preserves_newlines() {
        assert_eq!(
            sanitize_editor_text("first\nsecond\u{1b}[31m"),
            "first\nsecond [31m"
        );
    }
}
