import Foundation
@testable import IronPet

/// Synthetic windows with the shapes real apps expose, with invented text. Nothing here comes from a real chat, mailbox or screen.
enum TreeFixtures {
    struct Message {
        var id: Int
        var author: String
        var text: String
        var time: String
        /// A follow-up from the same author has no heading and no author anywhere in its subtree.
        var followUp = false
    }

    static let authors = ["Alex", "Sam", "Robin", "Jordan", "Taylor"]
    static let sentences = [
        "can you look at the build before lunch", "the release notes are ready for review", "I moved the standup to ten",
        "sounds good, thanks", "the invoice for the printer arrived", "we should plan the offsite in spring",
        "does the new onboarding doc cover the VPN", "pushed a fix for the flaky test", "lunch at noon?", "the demo went well",
    ]

    static func messages(_ count: Int, from start: Int = 0) -> [Message] {
        (start..<(start + count)).map { n in
            let author = authors[(n / 3) % authors.count]
            return Message(id: 9_000 + n, author: author, text: sentences[n % sentences.count] + " (\(n))",
                           time: String(format: "%02d:%02d", 9 + (n / 60) % 12, n % 60), followUp: n % 3 != 0)
        }
    }

    private static func text(_ value: String) -> AXNode { AXNode(role: "StaticText", value: value) }
    private static func grp(_ id: String, _ children: [AXNode]) -> AXNode { AXNode(role: "Group", domId: id, children: children) }
    private static func grp(name: String? = nil, _ children: [AXNode]) -> AXNode { AXNode(role: "Group", description: name, children: children) }
    private static func button(_ name: String) -> AXNode { AXNode(role: "Button", title: name) }

    /// A Discord-shaped message: a Group holding a labelled article, with the author in the name only for a follow-up.
    static func chatMessage(_ m: Message, channel: String = "c1") -> AXNode {
        let date = "Wednesday, 18. November 2026 at \(m.time)"
        var article: [AXNode] = []
        if !m.followUp {
            article.append(AXNode(role: "Heading", title: "\(m.author) \(m.time)", value: "3", children: [
                grp("message-username-\(m.id)", [button(m.author)]),
                grp("message-timestamp-\(m.id)", [text(m.time)]),
                text(date),
            ]))
            article.append(grp([AXNode(role: "Image", description: "avatar")]))
        } else {
            article.append(grp("message-timestamp-\(m.id)", [text(m.time), text(date)]))
        }
        article.append(grp("message-content-\(m.id)", [text(m.text)]))
        let actions = ["Click to react with thumbsup", "Click to react with eyes", "Reply", "Forward", "Edit", "Pin", "More", "Add reaction"]
        var controls: [AXNode] = []
        for name in actions { controls += [button(name), text(name.replacingOccurrences(of: "Click to react with ", with: "")), grp([text(name)])] }
        article.append(grp(name: "Message Actions", controls))
        let name = "\(m.author) , \(m.text) , \(m.time)"
        let articleNode = AXNode(role: "Group", subrole: "DocumentArticle", title: name, children: article)
        return grp("chat-messages-\(channel)-\(m.id)", [articleNode])
    }

    private static func wrap(_ depth: Int, _ inner: AXNode) -> AXNode {
        var node = inner
        for level in 0..<depth { node = grp([node]) }
        return node
    }

    /// A chat window: a channel sidebar, a message list 20 groups deep and a composer.
    static func discord(messages list: [Message], draft: String = "", sidebar: Int = 70) -> AXNode {
        let channels = grp(name: "Channels", (0..<sidebar).map { n in
            grp("channel-\(n)", [AXNode(role: "Link", title: "channel-\(n)", children: [text("channel-\(n)")]), button("Mute channel-\(n)"), text("\(n % 4) unread")])
        })
        let log = AXNode(role: "List", subrole: "Log", description: "Messages in #general", children: list.map { chatMessage($0) })
        let composer = grp(name: "Message bar", [AXNode(role: "TextArea", value: draft, description: "Message #general", domId: "composer"), button("Send"), button("Emoji")])
        let main = grp([wrap(20, log), composer])
        let toolbar = AXNode(role: "Toolbar", children: ["Back", "Forward", "Search", "Inbox", "Help"].map(button))
        return AXNode(role: "Window", title: "#general | Acme", children: [AXNode(role: "WebArea", url: "https://chat.example.com/channels/1/2", children: [toolbar, channels, main])])
    }

    /// A Slack-shaped list: list items with an author button and text, some named and some not, with no page ids.
    static func slack(messages list: [Message], draft: String = "", sidebar: Int = 60) -> AXNode {
        let items = list.map { m -> AXNode in
            var kids: [AXNode] = [button(m.author), AXNode(role: "Link", title: m.time, description: "Wednesday, November 18, 2026 at \(m.time)"), text(m.text)]
            kids.append(grp(name: "Message actions", ["Add reaction", "Reply in thread", "Forward message", "Save for later", "More actions"].map(button)))
            return AXNode(role: "ListItem", title: m.id % 2 == 0 ? "\(m.author): \(m.text)" : nil, children: kids)
        }
        let nav = AXNode(role: "List", description: "Channels", children: (0..<sidebar).map { AXNode(role: "ListItem", children: [AXNode(role: "Link", title: "team-\($0)", children: [text("team-\($0)")])]) })
        let composer = grp([AXNode(role: "TextArea", value: draft, description: "Message general"), button("Send now")])
        return AXNode(role: "Window", title: "general - Acme", children: [AXNode(role: "WebArea", url: "https://app.example.com/client/T1/C1", children: [AXNode(role: "Heading", title: "general", value: "1"), nav, wrap(8, AXNode(role: "List", description: "general", children: items)), composer])])
    }

    struct Mail {
        var id: Int
        var sender: String
        var subject: String
        var snippet: String
        var date: String
    }

    static func mails(_ count: Int, from start: Int = 0) -> [Mail] {
        (start..<(start + count)).map {
            Mail(id: $0, sender: authors[$0 % authors.count], subject: "Update \($0): " + sentences[$0 % sentences.count],
                 snippet: "Hi, " + sentences[($0 + 3) % sentences.count], date: "Wed, Nov 18, 2026, \(9 + $0 % 10):\(String(format: "%02d", $0 % 60)) AM")
        }
    }

    /// A Gmail-shaped table: rows of cells with page ids, the full date only in a cell's description.
    static func gmail(mails list: [Mail], reply: String = "", labels: Int = 80) -> AXNode {
        let rows = list.map { m -> AXNode in
            AXNode(role: "Row", domId: ":\(m.id)a", children: [
                AXNode(role: "Cell", children: [AXNode(role: "CheckBox", description: "Select"), button("Star")]),
                AXNode(role: "Cell", children: [text(m.sender)]),
                AXNode(role: "Cell", children: [text(m.subject), text(" - "), text(m.snippet)]),
                AXNode(role: "Cell", children: [AXNode(role: "StaticText", value: String(m.date.suffix(8)), description: m.date)]),
            ])
        }
        let side = AXNode(role: "List", description: "Labels", children: (0..<labels).map { AXNode(role: "ListItem", children: [AXNode(role: "Link", title: "Label \($0)")]) })
        let table = AXNode(role: "Table", description: "Inbox", children: rows)
        let compose = grp([AXNode(role: "TextArea", value: reply, description: "Message body")])
        return AXNode(role: "Window", title: "Inbox - mail", children: [AXNode(role: "WebArea", url: "https://mail.example.com/u/0/#inbox", children: [AXNode(role: "Heading", title: "Inbox", value: "2"), side, wrap(10, table), compose])])
    }

    /// A page of headings and paragraphs: no articles, list items or rows.
    static func article(paragraphs: Int = 120) -> AXNode {
        var kids: [AXNode] = [AXNode(role: "Heading", title: "Release notes", value: "1")]
        for n in 0..<paragraphs { kids.append(grp([text("Paragraph \(n): " + sentences[n % sentences.count]), AXNode(role: "Link", title: "Read more \(n)")])) }
        return AXNode(role: "Window", title: "Release notes", children: [AXNode(role: "WebArea", url: "https://docs.example.com/notes", children: kids)])
    }

    static func count(_ node: AXNode) -> Int { 1 + node.children.reduce(0) { $0 + count($1) } }
}
