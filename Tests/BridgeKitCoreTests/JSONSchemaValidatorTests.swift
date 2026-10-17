import Foundation
import Testing
@testable import BridgeKitCore

/// The validator's messages, against a small contract shaped like EK Bridge's tool inputs (shared
/// `$defs` fragments, nullable update fields, enums, consts, byte lengths, bounds and array rules),
/// so the golden messages carry over from EK Bridge's catalog tests.
@Suite("JSON Schema validator")
struct JSONSchemaValidatorTests {
    static let contractJSON = #"""
    {
      "$comment": "A test contract: only the features the validator supports.",
      "serverInstructions": "Validator test contract.",
      "$defs": {
        "$comment": "Shared fragments, inlined by ToolContract.",
        "dueInput": {"type": "object", "properties": {
          "date": {"type": "string"}, "date_time": {"type": "string"}, "time_zone": {"type": "string"},
          "none": {"type": "boolean", "const": true}}, "additionalProperties": false},
        "placeInput": {"type": "object", "required": ["title", "latitude", "longitude"], "properties": {
          "title": {"type": "string", "minLength": 1, "maxLength": 500},
          "latitude": {"type": "number", "minimum": -90, "maximum": 90},
          "longitude": {"type": "number", "minimum": -180, "maximum": 180}}, "additionalProperties": false},
        "alarmInput": {"type": "object", "properties": {
          "minutes_before": {"type": "integer", "minimum": -1440, "maximum": 40320},
          "proximity": {"type": "string", "enum": ["arrive", "leave"]}}, "additionalProperties": false},
        "recurrenceInput": {"type": "object", "properties": {
          "frequency": {"type": "string", "enum": ["daily", "weekly", "monthly", "yearly"]},
          "interval": {"type": "integer", "minimum": 1, "maximum": 366},
          "weekdays": {"type": "array", "minItems": 1, "maxItems": 7, "uniqueItems": true, "items": {"type": "string"}},
          "month_days": {"type": "array", "minItems": 1, "maxItems": 31, "uniqueItems": true,
                         "items": {"type": "integer", "minimum": -31, "maximum": 31}},
          "end": {"type": "object", "properties": {"count": {"type": "integer", "minimum": 1, "maximum": 10000},
                                                   "until": {"type": "string"}}, "additionalProperties": false},
          "day_of_month": {"type": "integer", "minimum": 1, "maximum": 31},
          "end_count": {"type": "integer", "minimum": 1, "maximum": 10000},
          "none": {"type": "boolean", "const": true}}, "additionalProperties": false}
      },
      "tools": [
        {"name": "list_collections", "inputSchema": {"type": "object", "properties": {}, "additionalProperties": false}},
        {"name": "read_events", "inputSchema": {"type": "object", "required": ["calendar_id", "start", "end"], "properties": {
          "calendar_id": {"type": "string"}, "start": {"type": "string"}, "end": {"type": "string"},
          "limit": {"type": "integer", "minimum": 1, "maximum": 100}, "cursor": {"type": "string"}},
          "additionalProperties": false}},
        {"name": "get_event", "inputSchema": {"type": "object", "required": ["calendar_id", "event_id"], "properties": {
          "calendar_id": {"type": "string"}, "event_id": {"type": "string"}}, "additionalProperties": false}},
        {"name": "create_event", "inputSchema": {"type": "object", "required": ["calendar_id", "title"], "properties": {
          "calendar_id": {"type": "string"}, "title": {"type": "string", "minLength": 1, "maxLength": 200},
          "all_day": {"type": "boolean"}, "notes": {"type": "string", "maxLength": 8000},
          "location": {"type": "string", "maxLength": 500},
          "structured_location": {"$ref": "#/$defs/placeInput"}, "url": {"type": "string", "maxLength": 2048},
          "alarms": {"type": "array", "maxItems": 5, "items": {"$ref": "#/$defs/alarmInput"}},
          "availability": {"type": "string", "enum": ["busy", "free", "tentative", "unavailable"]}},
          "additionalProperties": false}},
        {"name": "update_event", "inputSchema": {"type": "object", "required": ["calendar_id", "event_id", "version"],
          "properties": {
          "calendar_id": {"type": "string"}, "event_id": {"type": "string"}, "version": {"type": "string"},
          "span": {"type": "string", "enum": ["this", "future", "all"]},
          "title": {"type": "string", "minLength": 1, "maxLength": 200},
          "notes": {"type": ["string", "null"], "maxLength": 8000},
          "location": {"type": ["string", "null"], "maxLength": 500},
          "structured_location": {"type": ["object", "null"], "required": ["title", "latitude", "longitude"],
                                  "properties": {"title": {"type": "string"}, "latitude": {"type": "number"},
                                                 "longitude": {"type": "number"}}, "additionalProperties": false},
          "url": {"type": ["string", "null"], "maxLength": 2048},
          "alarms": {"type": ["array", "null"], "maxItems": 5, "items": {"$ref": "#/$defs/alarmInput"}},
          "availability": {"type": ["string", "null"], "enum": ["busy", "free", "tentative", "unavailable", null]}},
          "additionalProperties": false}},
        {"name": "read_reminders", "inputSchema": {"type": "object", "required": ["list_id"], "properties": {
          "list_id": {"type": "string"}, "limit": {"type": "integer", "minimum": 1, "maximum": 100},
          "cursor": {"type": "string"}, "status": {"type": "string", "enum": ["incomplete", "completed", "all"]},
          "due_after": {"type": "string"}, "due_before": {"type": "string"}}, "additionalProperties": false}},
        {"name": "create_reminder", "inputSchema": {"type": "object", "required": ["list_id", "title"], "properties": {
          "list_id": {"type": "string"}, "title": {"type": "string", "minLength": 1, "maxLength": 200},
          "due": {"$ref": "#/$defs/dueInput"}, "recurrence": {"$ref": "#/$defs/recurrenceInput"}},
          "additionalProperties": false}},
        {"name": "update_reminder", "inputSchema": {"type": "object", "required": ["list_id", "reminder_id", "version"],
          "properties": {
          "list_id": {"type": "string"}, "reminder_id": {"type": "string"}, "version": {"type": "string"},
          "title": {"type": "string", "minLength": 1, "maxLength": 200},
          "due": {"$ref": "#/$defs/dueInput"}, "recurrence": {"$ref": "#/$defs/recurrenceInput"},
          "priority": {"type": "string", "enum": ["none", "low", "medium", "high"]}}, "additionalProperties": false}},
        {"name": "complete_reminder", "inputSchema": {"type": "object", "required": ["list_id", "reminder_id", "version"],
          "properties": {
          "list_id": {"type": "string"}, "reminder_id": {"type": "string"}, "version": {"type": "string"},
          "occurrence": {"type": "object", "required": ["occurrence_due", "occurrence_fingerprint"], "properties": {
            "occurrence_due": {"type": "string"}, "occurrence_fingerprint": {"type": "string"}},
            "additionalProperties": false}}, "additionalProperties": false}},
        {"name": "delete_reminder", "inputSchema": {"type": "object", "required": ["list_id", "reminder_id", "version"],
          "properties": {
          "list_id": {"type": "string"}, "reminder_id": {"type": "string"}, "version": {"type": "string"},
          "scope": {"type": "string", "const": "series"}}, "additionalProperties": false}}
      ]
    }
    """#

    static let contract: ToolContract = {
        do { return try ToolContract(json: Data(contractJSON.utf8)) }
        catch { preconditionFailure("the test contract doesn't parse: \(error)") }
    }()

    struct Row: Sendable, CustomTestStringConvertible {
        let tool: String
        let json: String
        let expected: String?
        var testDescription: String { "\(tool) \(json.prefix(80))" }
    }

    static let long197 = String(repeating: "a", count: 197)

    static let goldens: [Row] = ([
        // Happy paths.
        ("list_collections", "{}", nil),
        ("read_events", #"{"calendar_id":"C","start":"2026-10-06T09:00:00Z","end":"2026-10-06T10:00:00Z","limit":2.0}"#, nil),
        ("create_reminder", #"{"list_id":"L","title":"t","due":{"date":"2026-10-06"},"recurrence":{"frequency":"weekly","weekdays":["MO","TU"],"interval":1}}"#, nil),
        ("create_event", #"{"calendar_id":"C","title":"\#(long197)é"}"#, nil), // 200 bytes
        // Missing required, first in schema order.
        ("read_events", "{}", "calendar_id: is required"),
        ("read_events", #"{"calendar_id":"C","end":"x"}"#, "start: is required"),
        ("complete_reminder", #"{"list_id":"L","reminder_id":"R","version":"1","occurrence":{}}"#,
         "occurrence.occurrence_due: is required"),
        // Unknown arguments.
        ("list_collections", #"{"foo":1}"#, "foo: isn't a known argument; this tool takes none"),
        ("read_reminders", #"{"list_id":"L","page":2}"#,
         "page: isn't a known argument (expected: cursor, due_after, due_before, limit, list_id, status)"),
        ("create_reminder", #"{"list_id":"L","title":"t","due":{"date":"2026-10-06","at":"9"}}"#,
         "due.at: isn't a known argument (expected: date, date_time, none, time_zone)"),
        // Wrong types.
        ("read_events", #"{"calendar_id":5,"start":"s","end":"e"}"#, "calendar_id: expected a string, got 5"),
        ("create_reminder", #"{"list_id":"L","title":"t","due":"tomorrow"}"#,
         #"due: expected an object, got "tomorrow""#),
        ("create_reminder", #"{"list_id":"L","title":"t","due":{"date_time":5}}"#,
         "due.date_time: expected a string, got 5"),
        ("create_reminder", #"{"list_id":"L","title":"t","recurrence":{"frequency":"weekly","weekdays":"MO"}}"#,
         #"recurrence.weekdays: expected an array, got "MO""#),
        ("read_reminders", #"{"list_id":null}"#, "list_id: expected a string, got null"),
        ("read_reminders", #"{"list_id":["L"]}"#, "list_id: expected a string, got an array"),
        // Booleans aren't integers, and integers aren't booleans.
        ("read_events", #"{"calendar_id":"C","start":"s","end":"e","limit":true}"#,
         "limit: expected a whole number, got true"),
        ("read_events", #"{"calendar_id":"C","start":"s","end":"e","limit":2.5}"#,
         "limit: expected a whole number, got 2.5"),
        ("read_events", #"{"calendar_id":"C","start":"s","end":"e","limit":"5"}"#,
         #"limit: expected a whole number, got "5""#),
        ("create_event", #"{"calendar_id":"C","title":"t","all_day":1}"#,
         "all_day: expected true or false, got 1"),
        ("create_event", #"{"calendar_id":"C","title":"t","all_day":"true"}"#,
         #"all_day: expected true or false, got "true""#),
        ("create_reminder", #"{"list_id":"L","title":"t","due":{"none":1}}"#,
         "due.none: expected true or false, got 1"),
        // Lengths in UTF-8 bytes: 199 characters, 201 bytes.
        ("create_event", #"{"calendar_id":"C","title":"\#(long197)éé"}"#,
         "title: must be at most 200 bytes of UTF-8, got 201"),
        ("create_event", #"{"calendar_id":"C","title":""}"#, "title: must not be empty"),
        ("create_event", #"{"calendar_id":"C","title":"t","notes":"\#(String(repeating: "€", count: 2_667))"}"#,
         "notes: must be at most 8000 bytes of UTF-8, got 8001"),
        ("create_event", #"{"calendar_id":"C","title":"t","notes":"\#(String(repeating: "€", count: 2_666))ab"}"#,
         nil),
        ("update_event", #"{"calendar_id":"C","event_id":"E","version":"1","notes":null,"url":null,"alarms":null,"availability":null,"structured_location":null,"location":null}"#,
         nil),
        ("update_event", #"{"calendar_id":"C","event_id":"E","version":"1","title":null}"#,
         "title: expected a string, got null"),
        ("update_event", #"{"calendar_id":"C","event_id":"E","version":"1","span":"most"}"#,
         #"span: expected one of "this", "future", "all", got "most""#),
        ("update_event", #"{"calendar_id":"C","event_id":"E","version":"1","availability":"away"}"#,
         #"availability: expected one of "busy", "free", "tentative", "unavailable", null, got "away""#),
        ("create_event", #"{"calendar_id":"C","title":"t","availability":null}"#,
         "availability: expected a string, got null"),
        ("create_event", #"{"calendar_id":"C","title":"t","alarms":[{},{},{},{},{},{}]}"#,
         "alarms: allows at most 5 items"),
        ("create_event", #"{"calendar_id":"C","title":"t","alarms":[{"minutes_before":40321}]}"#,
         "alarms[0].minutes_before: must be at most 40320"),
        ("create_event", #"{"calendar_id":"C","title":"t","alarms":[{"proximity":"near"}]}"#,
         #"alarms[0].proximity: expected one of "arrive", "leave", got "near""#),
        ("create_event", #"{"calendar_id":"C","title":"t","structured_location":{"title":"x","latitude":91,"longitude":0}}"#,
         "structured_location.latitude: must be at most 90"),
        ("create_event", #"{"calendar_id":"C","title":"t","url":"\#(String(repeating: "a", count: 2_049))"}"#,
         "url: must be at most 2048 bytes of UTF-8, got 2049"),
        ("create_reminder", #"{"list_id":"L","title":"t","recurrence":{"frequency":"monthly","month_days":[32]}}"#,
         "recurrence.month_days[0]: must be at most 31"),
        ("create_reminder", #"{"list_id":"L","title":"t","recurrence":{"frequency":"monthly","end":{"count":0}}}"#,
         "recurrence.end.count: must be at least 1"),
        ("read_reminders", #"{"list_id":"L","status":"done"}"#,
         #"status: expected one of "incomplete", "completed", "all", got "done""#),
        ("delete_reminder", #"{"list_id":"L","reminder_id":"R","version":"1","scope":"occurrence"}"#,
         #"scope: must be "series""#),
        ("update_reminder", #"{"list_id":"L","reminder_id":"R","version":"1","priority":null}"#,
         "priority: expected a string, got null"),
        ("get_event", #"{"calendar_id":"C"}"#, "event_id: is required"),
        // enum and const.
        ("create_reminder", #"{"list_id":"L","title":"t","recurrence":{"frequency":"hourly"}}"#,
         #"recurrence.frequency: expected one of "daily", "weekly", "monthly", "yearly", got "hourly""#),
        ("update_reminder", #"{"list_id":"L","reminder_id":"R","version":"1","title":"t","due":{"none":false}}"#,
         "due.none: must be true"),
        ("update_reminder", #"{"list_id":"L","reminder_id":"R","version":"1","title":"t","recurrence":{"none":false}}"#,
         "recurrence.none: must be true"),
        // minimum and maximum.
        ("read_events", #"{"calendar_id":"C","start":"s","end":"e","limit":0}"#, "limit: must be at least 1"),
        ("read_events", #"{"calendar_id":"C","start":"s","end":"e","limit":101}"#, "limit: must be at most 100"),
        ("read_reminders", #"{"list_id":"L","limit":-3}"#, "limit: must be at least 1"),
        ("create_reminder", #"{"list_id":"L","title":"t","recurrence":{"frequency":"daily","interval":367}}"#,
         "recurrence.interval: must be at most 366"),
        ("create_reminder", #"{"list_id":"L","title":"t","recurrence":{"frequency":"monthly","day_of_month":0}}"#,
         "recurrence.day_of_month: must be at least 1"),
        ("create_reminder", #"{"list_id":"L","title":"t","recurrence":{"frequency":"daily","end_count":10001}}"#,
         "recurrence.end_count: must be at most 10000"),
        // minItems, maxItems, uniqueItems and item types.
        ("create_reminder", #"{"list_id":"L","title":"t","recurrence":{"frequency":"weekly","weekdays":[]}}"#,
         "recurrence.weekdays: needs at least 1 item"),
        ("create_reminder", #"{"list_id":"L","title":"t","recurrence":{"frequency":"weekly","weekdays":["MO","TU","MO"]}}"#,
         #"recurrence.weekdays: "MO" appears more than once"#),
        ("create_reminder", #"{"list_id":"L","title":"t","recurrence":{"frequency":"weekly","weekdays":["MO","TU","WE","TH","FR","SA","SU","MO"]}}"#,
         "recurrence.weekdays: allows at most 7 items"),
        ("create_reminder", #"{"list_id":"L","title":"t","recurrence":{"frequency":"weekly","weekdays":["MO",5]}}"#,
         "recurrence.weekdays[1]: expected a string, got 5"),
        // Long values are shortened in messages.
        ("read_events", #"{"calendar_id":"C","start":"s","end":"e","limit":"\#(String(repeating: "x", count: 70))"}"#,
         #"limit: expected a whole number, got ""# + String(repeating: "x", count: 64) + #"…""#),
    ] as [(String, String, String?)]).map { Row(tool: $0.0, json: $0.1, expected: $0.2) }

    @Test("validator messages", arguments: goldens)
    func golden(_ row: Row) throws {
        let arguments = try #require(try JSONSerialization.jsonObject(with: Data(row.json.utf8)) as? [String: Any])
        let tool = try #require(Self.contract.tool(named: row.tool))
        #expect(JSONSchemaValidator.validate(arguments, against: tool.inputSchema) == row.expected)
    }

    @Test func goldenTable() throws {
        #expect(Self.goldens.count == 56)
        // The 201-byte title really is 199 characters.
        #expect((Self.long197 + "éé").count == 199 && (Self.long197 + "éé").utf8.count == 201)
        // Every shared fragment was inlined before validation.
        let text = String(decoding: try JSONSerialization.data(
            withJSONObject: Self.contract.tools.map(\.definition), options: [.sortedKeys]), as: UTF8.self)
        #expect(!text.contains("$ref") && !text.contains("$comment"))
    }

    /// Features the golden table doesn't reach.
    @Test("more schema features")
    func moreFeatures() throws {
        func check(_ schema: String, _ json: String) throws -> String? {
            let schema = try #require(try JSONSerialization.jsonObject(with: Data(schema.utf8)) as? [String: Any])
            let arguments = try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
            return JSONSchemaValidator.validate(arguments, against: schema)
        }
        let object = #"{"type": "object", "properties": {"x": %@}}"#
        func property(_ schema: String, _ value: String) throws -> String? {
            try check(object.replacingOccurrences(of: "%@", with: schema), #"{"x": \#(value)}"#)
        }
        // number accepts fractions; integer and number refuse booleans and strings.
        #expect(try property(#"{"type": "number"}"#, "2.5") == nil)
        #expect(try property(#"{"type": "number"}"#, "false") == "x: expected a number, got false")
        #expect(try property(#"{"type": "integer"}"#, "3") == nil)
        #expect(try property(#"{"type": "integer"}"#, "1e20") != nil, "past 2^53 isn't a safe whole number")
        // Several types, null and objects described in the message.
        #expect(try property(#"{"type": ["integer", "string"]}"#, "{}")
                == "x: expected a whole number or a string, got an object")
        #expect(try property(#"{"type": "null"}"#, "null") == nil)
        #expect(try property(#"{"type": "array"}"#, "{}") == "x: expected an array, got an object")
        #expect(try property(#"{"type": "object"}"#, "[]") == "x: expected an object, got an array")
        // Lengths beyond "not empty", counted in bytes.
        #expect(try property(#"{"type": "string", "minLength": 3}"#, #""éa""#) == nil, "3 bytes")
        #expect(try property(#"{"type": "string", "minLength": 3}"#, #""ab""#) == "x: must be at least 3 bytes")
        #expect(try property(#"{"type": "string", "maxLength": 2}"#, #""é""#) == nil)
        #expect(try property(#"{"type": "string", "maxLength": 2}"#, #""éa""#)
                == "x: must be at most 2 bytes of UTF-8, got 3")
        // Fractional bounds, and the plural in minItems.
        #expect(try property(#"{"type": "number", "minimum": 0.5}"#, "0.25") == "x: must be at least 0.5")
        #expect(try property(#"{"type": "number", "maximum": 1.5}"#, "1.5") == nil)
        #expect(try property(#"{"type": "array", "minItems": 2}"#, "[1]") == "x: needs at least 2 items")
        // const and enum keep booleans and numbers apart.
        #expect(try property(#"{"const": 1}"#, "true") == "x: must be 1")
        #expect(try property(#"{"const": true}"#, "1") == "x: must be true")
        #expect(try property(#"{"enum": [0, "a"]}"#, "false") == #"x: expected one of 0, "a", got false"#)
        #expect(try property(#"{"type": "array", "uniqueItems": true}"#, "[1, true]") == nil)
        #expect(try property(#"{"type": "array", "uniqueItems": true}"#, #"[{"a": 1}, {"a": 1}]"#)
                == "x: an object appears more than once")
        // Without additionalProperties false, unknown members pass; required paths nest.
        #expect(try check(#"{"type": "object", "properties": {"a": {"type": "string"}}}"#, #"{"b": 1}"#) == nil)
        #expect(try check(#"{"type": "object", "properties": {"a": {"type": "object", "properties": {"b": {"type": "object", "required": ["c"]}}}}}"#,
                          #"{"a": {"b": {}}}"#) == "a.b.c: is required")
        // Members are checked in name order, so the first problem is stable.
        #expect(try check(#"{"type": "object", "properties": {"a": {"type": "string"}, "b": {"type": "string"}}}"#,
                          #"{"b": 1, "a": 2}"#) == "a: expected a string, got 2")
        // The arguments object itself.
        #expect(try check(#"{"type": "object", "required": ["a"]}"#, "{}") == "a: is required")
        #expect(JSONSchemaValidator.validate([:], against: ["type": "array"]) == "arguments: expected an array, got an object")
    }
}
