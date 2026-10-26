/// One entry in the chat session. user/AI turns alternate.
class ChatMessage {
  final String role;        // 'user' | 'assistant' | 'system' | 'tool'
  final String content;     // markdown text
  final DateTime at;
  final String? toolUsed;   // if assistant used a tool, its name (recapture / websearch / highlight)
  final bool narrated;      // has this message been spoken via TTS already?

  const ChatMessage({
    required this.role,
    required this.content,
    required this.at,
    this.toolUsed,
    this.narrated = false,
  });

  ChatMessage copyWith({String? content, bool? narrated, String? toolUsed}) =>
      ChatMessage(
        role: role,
        content: content ?? this.content,
        at: at,
        toolUsed: toolUsed ?? this.toolUsed,
        narrated: narrated ?? this.narrated,
      );
}
