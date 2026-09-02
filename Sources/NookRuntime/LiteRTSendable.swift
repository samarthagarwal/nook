import LiteRTLM

// LiteRT-LM types are not marked Sendable yet; Nook only uses them on a single
// generation task at a time, so unchecked conformance is safe for this spike.
extension Conversation: @unchecked @retroactive Sendable {}
extension ConversationConfig: @unchecked @retroactive Sendable {}
extension LiteRTLM.Message: @unchecked @retroactive Sendable {}
