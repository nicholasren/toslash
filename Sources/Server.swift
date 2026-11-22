import Foundation
import Network
import SystemConfiguration

/// `defaults write io.github.nicholasren.toslash port 7788`, or launch with `-port 7788`.
let port: UInt16 = UInt16(exactly: UserDefaults.standard.integer(forKey: "port")).flatMap { $0 == 0 ? nil : $0 } ?? 80
/// The bare name links use, as in to/<name>. `defaults write … host go` picks another,
/// e.g. when a work VPN already answers to/. Restricted to a plain label, since it
/// goes into the /etc/hosts setup command.
let shortHost: String = {
    let host = UserDefaults.standard.string(forKey: "host")?.lowercased() ?? ""
    return host.wholeMatch(of: try! Regex("[a-z0-9]([a-z0-9-]*[a-z0-9])?")) != nil ? host : "to"
}()
let site = port == 80 ? shortHost : "localhost:\(port)"
let localHosts: Set<String> = ["localhost", "127.0.0.1", "::1", "[::1]", shortHost]
/// Lets other devices on the network read links. Toggled from the menu; `-allowNetwork YES` also works.
var allowNetwork: Bool {
    get { UserDefaults.standard.bool(forKey: "allowNetwork") }
    set { UserDefaults.standard.set(newValue, forKey: "allowNetwork") }
}

/// This Mac's Bonjour name, as in mac.local. Read each time, since the owner can rename the Mac.
func networkName() -> String? {
    (SCDynamicStoreCopyLocalHostName(nil) as String?).map { "\($0).local" }
}

enum ServerState: Equatable {
    case stopped, starting, running
    case failed(String)
}

/// Owns the listener. State changes and every method run on the main thread.
final class Server {
    private(set) var state = ServerState.stopped { didSet { onChange?() } }
    var onChange: (() -> Void)?
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "toslash.server")
    /// Set by start(), cleared by stop(). While set, a failed listen is retried, since the
    /// port can stay busy for a few seconds after a previous server exits.
    private var wanted = false

    var isActive: Bool { state == .running || state == .starting }

    func start() {
        wanted = true
        guard listener == nil else { return }
        // macOS lets an unprivileged process take port 80 only on the wildcard address,
        // so the listener binds there. Unless other devices are allowed, it is pinned to the
        // loopback interface and the kernel never hands it a connection from another machine.
        // route() still checks the peer.
        let allowNetwork = allowNetwork
        let parameters = NWParameters.tcp
        if !allowNetwork { parameters.requiredInterfaceType = .loopback }
        let listener: NWListener
        do {
            listener = try NWListener(using: parameters, on: NWEndpoint.Port(rawValue: port)!)
        } catch {
            fail(error.localizedDescription)
            return
        }
        listener.stateUpdateHandler = { [weak self] update in
            DispatchQueue.main.async {
                guard let self, self.listener === listener else { return }
                switch update {
                case .ready:
                    self.state = .running
                case .failed(let error), .waiting(let error):
                    self.listener = nil
                    listener.cancel()
                    self.fail(error.localizedDescription)
                default:
                    break
                }
            }
        }
        listener.newConnectionHandler = { [queue] connection in serve(connection, on: queue, allowNetwork: allowNetwork) }
        self.listener = listener
        state = .starting
        listener.start(queue: queue)
    }

    /// Calls `then` once the port is released, so a restart does not race the old listener.
    private func fail(_ reason: String) {
        state = .failed(reason)
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            guard let self, self.wanted, case .failed = self.state else { return }
            self.start()
        }
    }

    func stop(then next: (() -> Void)? = nil) {
        wanted = false
        guard let listener else {
            state = .stopped
            next?()
            return
        }
        self.listener = nil
        listener.stateUpdateHandler = { [weak self] update in
            guard case .cancelled = update else { return }
            DispatchQueue.main.async {
                self?.state = .stopped
                next?()
            }
        }
        listener.cancel()
    }

    func restart() {
        stop { [weak self] in self?.start() }
    }
}

// MARK: HTTP

struct Request {
    var method = "", path = "", query = ""
    var headers: [String: String] = [:]
    var body = Data()

    /// nil until the buffer holds the full head and body.
    init?(_ buffer: Data) {
        guard let end = buffer.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let lines = String(decoding: buffer[..<end.lowerBound], as: UTF8.self).components(separatedBy: "\r\n")
        for line in lines.dropFirst() {
            if let colon = line.firstIndex(of: ":") {
                headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            }
        }
        let length = Int(headers["content-length"] ?? "") ?? 0
        guard buffer.count - end.upperBound >= length else { return nil }
        body = Data(buffer[end.upperBound...].prefix(length))
        let parts = lines[0].split(separator: " ")
        if parts.count >= 2 {
            method = String(parts[0])
            let target = parts[1].split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
            path = String(target[0])
            query = target.count > 1 ? String(target[1]) : ""
        }
    }
}

struct Response {
    var status: Int
    var location: String?
    var body = ""
    var contentType = "text/html; charset=utf-8"
    /// Sent instead of `body` when set, for non-text responses.
    var binary: Data?

    static func json(_ status: Int, _ value: some Encodable) -> Response {
        Response(status: status, body: String(decoding: try! encoder.encode(value), as: UTF8.self) + "\n",
                 contentType: "application/json")
    }

    var bytes: Data {
        let reasons = [200: "OK", 302: "Found", 303: "See Other", 400: "Bad Request", 403: "Forbidden",
                       404: "Not Found", 405: "Method Not Allowed"]
        var head = "HTTP/1.1 \(status) \(reasons[status] ?? "")\r\n"
        if let location { head += "Location: \(location)\r\nCache-Control: no-store\r\n" }
        let data = binary ?? Data(body.utf8)
        if !data.isEmpty { head += "Content-Type: \(contentType)\r\n" }
        if binary != nil { head += "Cache-Control: max-age=86400\r\n" }
        head += "Content-Length: \(data.count)\r\nConnection: close\r\n\r\n"
        return Data(head.utf8) + data
    }
}

private func serve(_ connection: NWConnection, on queue: DispatchQueue, allowNetwork: Bool) {
    connection.start(queue: queue)
    let client = Client(connection.endpoint)
    receive(connection, Data()) { route($0, from: client, allowNetwork: allowNetwork) }
}

private func receive(_ connection: NWConnection, _ buffer: Data, _ respond: @escaping (Request) -> Response) {
    connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, done, error in
        var buffer = buffer
        if let data { buffer.append(data) }
        if let request = Request(buffer) {
            // Off the network queue: a page view checks hosts and can take half a second.
            DispatchQueue.global().async {
                let response = respond(request)
                connection.send(content: response.bytes, completion: .contentProcessed { _ in connection.cancel() })
            }
        } else if done || error != nil || buffer.count > 1 << 20 {
            connection.cancel()
        } else {
            receive(connection, buffer, respond)
        }
    }
}

enum Client {
    case thisMac, otherDevice

    init(_ peer: NWEndpoint) {
        guard case .hostPort(let host, _) = peer else { self = .otherDevice; return }
        let loopback = switch host {
        case .ipv4(let address): address.isLoopback
        case .ipv6(let address): address.isLoopback || address.asIPv4?.isLoopback == true
        default: false
        }
        self = loopback ? .thisMac : .otherDevice
    }

    /// Host names its requests may carry. A name outside these reaches the server only
    /// because some DNS points it here (DNS rebinding), so the request is refused.
    func accepts(_ host: String) -> Bool {
        switch self {
        case .thisMac:
            return localHosts.contains(host)
        case .otherDevice:
            let bracketed = host.hasPrefix("[") && host.hasSuffix("]")
            return IPv4Address(host) != nil || (bracketed && IPv6Address(String(host.dropFirst().dropLast())) != nil)
                || host == shortHost || host.caseInsensitiveCompare(networkName() ?? "") == .orderedSame
        }
    }
}

/// What a request may do. Every method but GET counts as a write.
enum Access {
    case denied, read, readWrite

    init(_ client: Client, allowNetwork: Bool) {
        switch (client, allowNetwork) {
        case (.thisMac, _): self = .readWrite
        case (.otherDevice, false): self = .denied
        case (.otherDevice, true): self = .read
        }
    }

    func allows(_ method: String) -> Bool {
        switch self {
        case .denied: false
        case .read: method == "GET"
        case .readWrite: true
        }
    }
}

// MARK: Routes

func route(_ request: Request, from client: Client, allowNetwork: Bool) -> Response {
    let hostHeader = request.headers["host"] ?? ""
    let host = URLComponents(string: "//" + hostHeader)?.percentEncodedHost ?? ""
    let access = Access(client, allowNetwork: allowNetwork)
    guard access.allows(request.method), client.accepts(host) else { return Response(status: 403, body: "forbidden") }
    let view = client == .thisMac ? PageView(site: site, editable: true) : PageView(site: hostHeader, editable: false)
    // Browsers send Origin on writes, so a page on another site cannot change links.
    if request.method != "GET", let origin = request.headers["origin"], hostAndPort(origin) != request.headers["host"] {
        return Response(status: 403, body: "forbidden")
    }
    if request.path == apiPath || request.path.hasPrefix(apiPath + "/") { return api(request) }
    switch request.method {
    case "GET":
        let path = request.path.dropFirst()
        let name = String(path.prefix { $0 != "/" })
        let rest = String(path.dropFirst(name.count + 1))
        let links = Store.shared.links
        if name.isEmpty { return Response(status: 200, body: page(links, view)) }
        if request.path == iconPath {
            guard let pageIcon else { return Response(status: 404) }
            return Response(status: 200, contentType: "image/png", binary: pageIcon)
        }
        if let link = links.first(where: { $0.name == name })?.link {
            let url = client == .thisMac ? link.url : reachable(link.url, at: host)
            return Response(status: 302, location: target(url, rest, request.query))
        }
        if name == "favicon.ico" { return Response(status: 404) }
        let missing = "No link \"\(name)\"." + (view.editable ? " Add it below." : "")
        return Response(status: 404, body: page(links, view, message: failure(missing), name: name))
    case "POST":
        let form = parseForm(request.body)
        let field = { (key: String) in form[key, default: ""].trimmingCharacters(in: .whitespaces) }
        let error: String?
        switch request.path {
        case "/_/add":
            error = Store.shared.save(name: field("name"), url: field("url"), description: field("description"),
                                      replacing: field("old").isEmpty ? nil : field("old"))
        case "/_/rm":
            error = Store.shared.remove(field("name"))
        default:
            return Response(status: 404)
        }
        if let error {
            return Response(status: 400, body: page(Store.shared.links, view, message: failure(error), name: field("name"),
                                                    url: field("url"), description: field("description"), old: field("old")))
        }
        return Response(status: 303, location: "/")
    default:
        return Response(status: 405)
    }
}

/// Under /_/, which no link name can start with.
let iconPath = "/_/icon.png"

// MARK: API

/// JSON for agents and scripts. PUT is create-or-update, so a retry never fails on an existing name.
/// PUT and DELETE from a web page need a CORS preflight this server never grants.
let apiPath = "/_/api/links"

private struct APILink: Encodable {
    let name, url: String
    let description: String?
    let created: Date
    let link: String

    init(_ name: String, _ link: Link) {
        (self.name, url, description, created) = (name, link.url, link.description, link.created)
        self.link = "http://\(site)/\(name)"
    }
}

private struct PutBody: Decodable {
    let url: String
    let description: String?
}

private func api(_ request: Request) -> Response {
    let name = String(request.path.dropFirst(apiPath.count).drop { $0 == "/" })
    let usage = ["error": "use GET \(apiPath), or GET, PUT or DELETE \(apiPath)/<name>"]
    switch (request.method, name.isEmpty) {
    case ("GET", true):
        return .json(200, Store.shared.links.map { APILink($0.name, $0.link) })
    case ("GET", false):
        guard let link = Store.shared.link(name) else { return .json(404, ["error": "no link named \"\(name)\""]) }
        return .json(200, APILink(name, link))
    case ("PUT", false):
        guard let body = try? JSONDecoder().decode(PutBody.self, from: request.body) else {
            return .json(400, ["error": "send JSON like {\"url\": \"https://…\", \"description\": \"…\"}"])
        }
        if let error = Store.shared.put(name: name, url: body.url, description: body.description) {
            return .json(400, ["error": error])
        }
        return .json(200, APILink(name, Store.shared.link(name)!))
    case ("DELETE", false):
        if let error = Store.shared.remove(name) { return .json(400, ["error": error]) }
        return .json(200, ["deleted": name])
    default:
        return .json(405, usage)
    }
}

/// A link to this Mac's loopback, rewritten to the host another device used to reach this Mac.
/// `host` is percent-encoded and bracketed for IPv6, as URLComponents keeps it.
func reachable(_ url: String, at host: String) -> String {
    guard var parts = URLComponents(string: url), let saved = parts.host?.lowercased(),
          ["localhost", "127.0.0.1", "::1", "[::1]"].contains(saved) else { return url }
    parts.percentEncodedHost = host
    return parts.string ?? url
}

func target(_ url: String, _ rest: String, _ query: String) -> String {
    var out = url
    if !rest.isEmpty {
        while out.hasSuffix("/") { out.removeLast() }
        out += "/" + rest
    }
    if !query.isEmpty { out += (out.contains("?") ? "&" : "?") + query }
    return out
}

private func hostAndPort(_ origin: String) -> String? {
    guard let url = URLComponents(string: origin), let host = url.percentEncodedHost else { return nil }
    return url.port.map { "\(host):\($0)" } ?? host
}

private func parseForm(_ body: Data) -> [String: String] {
    var form: [String: String] = [:]
    let decode = { (s: Substring) in s.replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? "" }
    for pair in String(decoding: body, as: UTF8.self).split(separator: "&") {
        let kv = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
        form[decode(kv[0])] = kv.count > 1 ? decode(kv[1]) : ""
    }
    return form
}

// MARK: Page

private func esc(_ s: String) -> String {
    s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
        .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
}

private func failure(_ message: String) -> String { "<span class=err>\(esc(message))</span>" }

private let day: DateFormatter = {
    let f = DateFormatter()
    f.dateStyle = .medium
    return f
}()

struct PageView {
    let site: String
    let editable: Bool
}

private func page(_ links: [(name: String, link: Link)], _ view: PageView, message: String = "", name: String = "",
                  url: String = "", description: String = "", old: String = "") -> String {
    let rows = zip(links, statuses(links.map(\.link.url))).map { entry, up in
        let dot = up.map { "<span class=\"dot \($0 ? "up" : "down")\" title=\"\($0 ? "up" : "not reachable")\"></span>" } ?? ""
        let (n, u, d) = (esc(entry.name), esc(entry.link.url), esc(entry.link.description ?? ""))
        let about = d.isEmpty ? "" : "<div class=d>\(d)</div>"
        let controls = view.editable ? """
        <td><button type=button class=edit data-name="\(n)" data-url="\(u)" data-description="\(d)">edit</button></td>\
        <td><form method=post action=/_/rm><input type=hidden name=name value="\(n)"><button>remove</button></form></td>
        """ : ""
        return """
        <tr><td>\(dot)</td><td class=l><a href="/\(n)">\(n)</a>\(about)<div class=u>\(u)</div></td>\
        <td class=c>\(day.string(from: entry.link.created))</td>\(controls)</tr>
        """
    }.joined()
    let intro = view.editable
        ? "\(esc(view.site))/&lt;name&gt; redirects to the saved URL. Extra path and query are passed through."
        : "http://\(esc(view.site))/&lt;name&gt; redirects to the saved URL. Extra path and query are passed through. "
            + "Links can be changed only on the Mac running ToSlash."
    let addForm = """
    <form class=add method=post action=/_/add><input type=hidden name=old value="\(esc(old))">
    <input name=name placeholder=name value="\(esc(name))" required><input name=url placeholder="http://localhost:3000 or https://claude.ai/..." value="\(esc(url))" required>
    <button class=save>Save</button><button type=button class=cancel hidden>Cancel</button>
    <input name=description placeholder="description (optional)" value="\(esc(description))"></form>
    """
    let editScript = """
    <script>
    const f = document.querySelector('form.add');
    const [old, name, url, about] = ['old', 'name', 'url', 'description'].map(k => f.elements.namedItem(k));
    const save = f.querySelector('.save'), cancel = f.querySelector('.cancel');
    const editing = on => { save.textContent = on ? 'Update' : 'Save'; cancel.hidden = !on; };
    for (const b of document.querySelectorAll('.edit')) b.onclick = () => {
      old.value = name.value = b.dataset.name; url.value = b.dataset.url; about.value = b.dataset.description;
      editing(true); scrollTo(0, 0); url.focus(); url.select();
    };
    cancel.onclick = () => { old.value = name.value = url.value = about.value = ''; editing(false); };
    f.onkeydown = e => { if (e.key === 'Escape') cancel.onclick(); };
    editing(!!old.value);
    </script>
    """
    return """
    <!doctype html><meta charset=utf-8><meta name=viewport content="width=device-width">
    <title>ToSlash</title><link rel=icon href=\(iconPath)><link rel=apple-touch-icon href=\(iconPath)>
    <style>
    :root{--bg:#fff;--fg:#1a1a1a;--mute:#6b6b6b;--line:#e5e5e5;--up:#1a7f37;--down:#c62828;--accent:#0b57d0}
    @media (prefers-color-scheme:dark){:root{--bg:#151515;--fg:#e8e8e8;--mute:#9a9a9a;--line:#2c2c2c;--up:#3fb950;--down:#f47067;--accent:#7aa7ff}}
    body{background:var(--bg);color:var(--fg);font:15px/1.5 -apple-system,system-ui,sans-serif;max-width:860px;margin:32px auto;padding:0 16px}
    h1{font-size:20px;margin:0 0 4px;display:flex;align-items:center;gap:8px} h1 img{width:28px;height:28px} p{color:var(--mute);margin:0 0 20px}
    table{width:100%;border-collapse:collapse} td{padding:8px 6px;border-top:1px solid var(--line);vertical-align:middle}
    a{color:var(--accent);text-decoration:none;font-weight:600} td.l{width:100%}
    .d{font-size:13px} .u{color:var(--mute);word-break:break-all;font-size:12px}
    td.c{color:var(--mute);font-size:13px;white-space:nowrap}
    @media (max-width:600px){td.c{display:none}}
    .dot{display:inline-block;width:8px;height:8px;border-radius:50%} .up{background:var(--up)} .down{background:var(--down)}
    form.add{display:flex;gap:8px;flex-wrap:wrap;margin:20px 0} input{font:inherit;padding:6px 8px;border:1px solid var(--line);border-radius:6px;background:var(--bg);color:var(--fg)}
    input[name=name]{width:140px} input[name=url]{flex:1;min-width:220px} input[name=description]{flex-basis:100%}
    button{font:inherit;padding:6px 12px;border:1px solid var(--line);border-radius:6px;background:var(--bg);color:var(--fg);cursor:pointer}
    td form{margin:0} td button{padding:2px 8px;font-size:13px;color:var(--mute)} .err{color:var(--down)}
    input.filter{width:100%;box-sizing:border-box;margin:0 0 4px}
    </style>
    <h1><img src=\(iconPath) alt="">ToSlash</h1><p>\(message.isEmpty ? intro : message)</p>
    \(view.editable ? addForm : "")
    \(rows.isEmpty ? "" : "<input type=search class=filter placeholder=\"Filter links (press /)\" aria-label=\"Filter links\">")
    <table>\(rows.isEmpty ? "<tr><td>No links yet.</td></tr>" : rows)</table>
    \(view.editable ? editScript : "")
    <script>
    const filter = document.querySelector('.filter');
    if (filter) {
      filter.oninput = () => {
        const q = filter.value.trim().toLowerCase();
        for (const row of document.querySelectorAll('tr')) row.hidden = !!q && !row.querySelector('td.l').textContent.toLowerCase().includes(q);
      };
      filter.onkeydown = e => { if (e.key === 'Escape') { filter.value = ''; filter.oninput(); } };
      document.addEventListener('keydown', e => {
        if (e.key === '/' && !(e.target instanceof HTMLInputElement)) { e.preventDefault(); filter.focus(); }
      });
    }
    </script>
    """
}
