// Preserve source action identity before the compatible provider drops message
// IDs. This plugin is installed only in Aiur's dedicated chat-slot workspace.
export default async function inputIdentity() {
  const transformed = new WeakSet();
  return {
    "chat.headers": async (input, output) => {
      if (input.model.providerID === "aiur") {
        output.headers["x-aiur-input-version"] = "1";
      }
    },
    "experimental.chat.messages.transform": async (_input, output) => {
      for (let i = 0; i < output.messages.length; i++) {
        const message = output.messages[i];
        if (message.info.role !== "user" || transformed.has(message)) continue;
        const parts = message.parts.filter((part) => part.type === "text" && !part.ignored);
        const text = parts.map((part) => part.text).join("");
        const envelope = "__aiur_input_v1__:" + JSON.stringify({
          session: message.info.sessionID,
          message: message.info.id,
          text,
        });
        // Replace array entries with new objects: never mutate persisted parts
        // or emit UI events. Do not detect envelopes by text: the user may type
        // that exact text intentionally, and it must receive its own identity.
        const replacement = {
          ...message,
          parts: [
            { ...parts[0], type: "text", text: envelope },
            ...message.parts.filter((part) => part.type !== "text"),
          ],
        };
        transformed.add(replacement);
        output.messages[i] = replacement;
      }
    },
  };
}
