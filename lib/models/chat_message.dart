import 'citation.dart';

/// One entry in the chat session. user/AI turns alternate.
class ChatMessage {
  final String role; // 'user' | 'assistant' | 'system' | 'tool'
  final String content; // markdown text
  final DateTime at;
  final String? toolUsed; // if assistant used a tool, its name (recapture / websearch / highlight)
  final bool narrated; // has this message been spoken via TTS already?
  final List<Citation> citations; // attached sources for assistant replies
  final int verifiedCount;
  final int unverifiedCount;

  const ChatMessage({
    required this.role,
    required this.content,
    required this.at,
    this.toolUsed,
    this.narrated = false,
    this.citations = const [],
    this.verifiedCount = 0,
    this.unverifiedCount = 0,
  });

  ChatMessage copyWith({
    String? content,
    bool? narrated,
    String? toolUsed,
    List<Citation>? citations,
    int? verifiedCount,
    int? unverifiedCount,
  }) =>
      ChatMessage(
        role: role,
        content: content ?? this.content,
        at: at,
        toolUsed: toolUsed ?? this.toolUsed,
        narrated: narrated ?? this.narrated,
        citations: citations ?? this.citations,
        verifiedCount: verifiedCount ?? this.verifiedCount,
        unverifiedCount: unverifiedCount ?? this.unverifiedCount,
      );
}
