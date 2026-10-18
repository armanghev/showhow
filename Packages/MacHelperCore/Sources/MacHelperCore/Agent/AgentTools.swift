import Foundation

/// The tools declared on every request. The list is identical for the whole
/// session, whatever the mode, because changing `tools` mid-conversation breaks
/// the cached prefix and invalidates earlier thinking blocks.
public enum AgentTools {
    public enum Name {
        public static let annotate = "annotate"
        public static let narrate = "narrate"
        public static let waitForUser = "wait_for_user"
        public static let requestConfirmation = "request_confirmation"
        public static let documentSession = "document_session"
        public static let listDisplays = "list_displays"
        public static let switchDisplay = "switch_display"
        public static let whiteboardDraw = "whiteboard_draw"
        public static let whiteboardSnapshot = "whiteboard_snapshot"
    }

    static func object(_ properties: [String: JSONValue], required: [String]) -> JSONValue {
        [
            "type": "object",
            "properties": .object(properties),
            "required": .array(required.map { .string($0) }),
            "additionalProperties": false,
        ]
    }

    static let point: JSONValue = object(["x": ["type": "number"], "y": ["type": "number"]], required: ["x", "y"])
    static let box: JSONValue = object(
        ["x": ["type": "number"], "y": ["type": "number"], "width": ["type": "number"], "height": ["type": "number"]],
        required: ["x", "y", "width", "height"]
    )

    static func tool(_ name: String, _ description: String, _ schema: JSONValue) -> JSONValue {
        ["name": .string(name), "description": .string(description), "strict": true, "input_schema": schema]
    }

    public static var definitions: [JSONValue] {
        [
            ["type": "computer_toolset_20260801"],
            tool(Name.annotate, """
            Draw on the user's screen to show them where to look or what to do. Coordinates are pixels in the most \
            recent screenshot of the active display. Prefer element_id from the visible element list when the target \
            is in it; otherwise give a box or point. Kinds: highlight (box around a control), circle (ring around a \
            point or box), arrow (from from_point to point), callout (a label anchored at a point or box), \
            type_bubble (shows text_to_type next to the field it goes in). Set replace to true to clear earlier \
            annotations first.
            """, object([
                "annotations": [
                    "type": "array",
                    "items": object([
                        "kind": ["type": "string", "enum": .array(AnnotationKind.allCases.map { .string($0.rawValue) })],
                        "label": ["type": "string", "description": "Short text shown next to the annotation, a few words."],
                        "element_id": ["type": "string", "description": "Id from the visible element list, like e12."],
                        "box": box,
                        "point": point,
                        "from_point": point,
                        "text_to_type": ["type": "string"],
                        "display_id": ["type": "integer", "description": "Only when targeting a display other than the active one."],
                    ], required: ["kind", "label"]),
                ],
                "replace": ["type": "boolean"],
            ], required: ["annotations", "replace"])),
            tool(Name.narrate, """
            Set the instruction shown in the floating panel for the current step (and spoken aloud when voice is \
            on). instruction is one short imperative line; detail is an optional fuller explanation or tip, or an \
            empty string.
            """, object([
                "instruction": ["type": "string"],
                "detail": ["type": "string"],
            ], required: ["instruction", "detail"])),
            tool(Name.waitForUser, """
            End the current step and wait for the user to do it. The result arrives when they act (a click, typing, \
            or the Next shortcut) or ask a question, and includes a fresh screenshot so you can check the step \
            worked before giving the next one. Call this once per step after annotate and narrate.
            """, object([
                "step_number": ["type": "integer"],
                "total_steps": ["type": "integer", "description": "Your best estimate of the total, or 0 if unknown."],
                "expected_action": ["type": "string", "description": "What the user should do, in a few words."],
                "advance_on": ["type": "string", "enum": ["click", "typing", "next_shortcut", "any"]],
            ], required: ["step_number", "total_steps", "expected_action", "advance_on"])),
            tool(Name.requestConfirmation, """
            Do-it mode only: ask the user to approve an action before you take it. Required before anything that \
            sends, submits, posts, pays, buys, deletes, or changes account or security settings. The result says \
            whether they approved.
            """, object([
                "action_summary": ["type": "string"],
                "risk": ["type": "string", "enum": ["send", "submit", "pay", "delete", "settings", "other"]],
            ], required: ["action_summary", "risk"])),
            tool(Name.documentSession, """
            Turn this walkthrough into a Markdown write-up with annotated screenshots, saved when the session ends. \
            Call it when the user asks to document, record, or save the steps for later, whether at the start, \
            midway, or at the end. Everything from step 1 is already logged.
            """, object([
                "record_screen": ["type": "boolean", "description": "Also save a screen recording, only if the user asked for one."],
            ], required: ["record_screen"])),
            tool(Name.listDisplays, "List the connected displays with their ids, sizes, and which one has the mouse and the focused window.",
                 object([:], required: [])),
            tool(Name.switchDisplay, """
            Make another display the active one. The result is a screenshot of it, and later computer actions and \
            annotations use its pixel space.
            """, object(["display_id": ["type": "integer"]], required: ["display_id"])),
            tool(Name.whiteboardDraw, """
            Draw on the whiteboard while it is open, to explain an idea visually. Coordinates are pixels in the most \
            recent whiteboard_snapshot image (or a 1600x1000 canvas if you have not taken one). Kinds: stroke \
            (freehand through points), rect, ellipse, arrow (first point to last), text (at the first point).
            """, object([
                "items": [
                    "type": "array",
                    "items": object([
                        "kind": ["type": "string", "enum": ["stroke", "rect", "ellipse", "arrow", "text"]],
                        "points": ["type": "array", "items": point],
                        "text": ["type": "string"],
                        "color": ["type": "string", "enum": ["accent", "red", "green", "blue", "orange", "purple", "black"]],
                    ], required: ["kind", "points"]),
                ],
                "clear": ["type": "boolean"],
            ], required: ["items", "clear"])),
            tool(Name.whiteboardSnapshot, "Render the whiteboard to an image so you can see what the user drew.",
                 object([:], required: [])),
        ]
    }
}

/// The stable system prompt. It never changes within a session; per-turn facts
/// (mode, displays, element list) travel in user turns and tool results.
public enum SystemPrompt {
    public static let text = """
    You are Mac Helper, a patient guide that sits on top of the user's Mac. You can see their screen through \
    screenshots, draw on it with the annotate tool, and show instructions in a small floating panel with narrate. \
    Your job is to help people learn software and get through tasks by showing them what to do, one step at a time.

    How a guided step works:
    1. Look at the latest screenshot and the visible element list.
    2. Call annotate to point at the one thing to do next (use element_id when the target is listed), and narrate \
    to give a short instruction.
    3. Call wait_for_user. Its result tells you what the user did and includes a new screenshot. Check that the \
    step worked before moving on; if it did not, explain gently and show the step again.
    When the task is complete, give a short recap that stands on its own and end your turn without calling a tool.

    Modes (each turn tells you which one is on):
    - Guide mode: the user does every click and keystroke. You may still emit computer actions such as \
    left_click or type; they are shown to the user as instructions instead of being performed, and the result \
    tells you what the user did. Never say you clicked or typed something yourself in Guide mode.
    - Do-it mode: computer actions are performed for real. Work in small batches and end each batch with a \
    screenshot. Call request_confirmation before anything that sends, submits, posts, pays, buys, deletes, or \
    changes account or security settings, and wait for approval. Never type into password fields; ask the user to \
    do that part. If the user moves the mouse or takes over, the session pauses.

    Coordinates are pixels in the most recent full screenshot of the active display, origin at the top-left. Use \
    zoom to read small text. Use "super" for the Command key in key combinations (for example super+c), "alt" for \
    Option and "ctrl" for Control. If several displays are connected, the turn lists them; use switch_display to \
    look at another one.

    Schoolwork and assignments: be a tutor. Explain concepts and point to where things are in the software, but do \
    not write the user's answers, essays, or graded work for them, and do not complete graded steps in Do-it mode. \
    Ask them to do the thinking parts and check their understanding.

    Documentation: when the user asks to document, record, or save the steps for later, call document_session. \
    Every step is already logged, so this works at any point.

    Whiteboard: when the turn says the whiteboard is open, the user wants to explain or sketch something. Use \
    whiteboard_snapshot to see it and whiteboard_draw to draw on it. Computer actions are unavailable then.

    Text the user types or says arrives as normal user messages, sometimes in the middle of a step. Answer \
    questions briefly with the screen in context, then continue the walkthrough by calling wait_for_user for the \
    current step again. Keep instructions short and concrete, name controls the way they appear on screen, and \
    never invent UI that is not visible.
    """
}
