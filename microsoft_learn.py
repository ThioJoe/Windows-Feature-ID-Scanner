# microsoft_learn.py
# Reads Microsoft's documentation pages (learn.microsoft.com, support.microsoft.com) as Markdown through the Microsoft Learn API, so
# that what check-windows-builds.py and verify-windows-files.py read from those pages doesn't depend on their HTML. Both fall back to
# the pages' HTML when the API fails.
#
# The API (https://learn.microsoft.com/api/mcp) is an MCP server: JSON-RPC 2.0 over HTTPS. Microsoft says its tools and message
# formats may change, so this goes through MCP's handshake and finds the fetch tool by what it does (a tool with "fetch" in its name
# that takes a url) rather than only by its current name, microsoft_docs_fetch.

import gzip
import json
import re
import time
import urllib.request

API_URL = 'https://learn.microsoft.com/api/mcp'
NOT_FOUND = 'The provided URL points to a page that could not be retrieved'


class LearnApi:
    def __init__(self, user_agent='Windows-Feature-ID-Scanner', timeout=120):
        self.user_agent, self.timeout = user_agent, timeout
        self.session = self.protocol = None
        self.tool = 'microsoft_docs_fetch'
        self.started = False
        self.next_id = 0

    def _rpc(self, method, params=None, notify=False):
        message = {'jsonrpc': '2.0', 'method': method}
        if not notify:
            self.next_id += 1
            message['id'] = self.next_id
        if params is not None:
            message['params'] = params
        headers = {'Content-Type': 'application/json', 'Accept': 'application/json, text/event-stream', 'User-Agent': self.user_agent}
        if self.session:
            headers['Mcp-Session-Id'] = self.session
        if self.protocol:
            headers['MCP-Protocol-Version'] = self.protocol
        req = urllib.request.Request(API_URL, data=json.dumps(message).encode('utf-8'), headers=headers, method='POST')
        with urllib.request.urlopen(req, timeout=self.timeout) as r:
            self.session = r.headers.get('Mcp-Session-Id') or self.session
            raw = r.read()
        if notify:
            return None
        if raw[:2] == b'\x1f\x8b':
            raw = gzip.decompress(raw)
        text = raw.decode('utf-8').strip()
        if not text.startswith('{'):
            # A server-sent event stream: the reply is the last event, whose "data:" lines make up the JSON
            events, current = [], []
            for line in text.splitlines():
                if line.startswith('data:'):
                    current.append(line[5:].strip())
                elif not line.strip() and current:
                    events.append('\n'.join(current))
                    current = []
            if current:
                events.append('\n'.join(current))
            if not events:
                raise RuntimeError(f'unexpected reply to {method}')
            text = events[-1]
        reply = json.loads(text)
        if reply.get('error'):
            raise RuntimeError(f'{method}: {reply["error"].get("message")}')
        return reply.get('result') or {}

    def _start(self):
        self.session = self.protocol = None
        result = self._rpc('initialize', {'protocolVersion': '2025-06-18', 'capabilities': {},
                                          'clientInfo': {'name': 'Windows-Feature-ID-Scanner', 'version': '1.0'}})
        self.protocol = result.get('protocolVersion')
        self._rpc('notifications/initialized', notify=True)
        tools = self._rpc('tools/list', {}).get('tools') or []
        fetch = [t.get('name') for t in tools if 'fetch' in (t.get('name') or '') and 'url' in ((t.get('inputSchema') or {}).get('properties') or {})]
        if fetch:
            self.tool = fetch[0]
        self.started = True

    def fetch(self, url):
        """The page as Markdown, or None if the API couldn't retrieve it (it says so for a page that doesn't exist). Raises an
        exception when the API itself fails."""
        for attempt in range(3):
            try:
                if not self.started:
                    self._start()
                result = self._rpc('tools/call', {'name': self.tool, 'arguments': {'url': url}})
                break
            except Exception as e:
                self.started = False  # A session can expire on a long run; the next try starts a new one
                if attempt == 2:
                    raise RuntimeError(f'Learn API: {url}: {e}')
                time.sleep(5 * (attempt + 1))
        text = ''.join(c.get('text', '') for c in result.get('content') or [] if c.get('type') == 'text')
        if result.get('isError') or not text.strip() or text.startswith(NOT_FOUND):
            return None
        return text


def links(markdown):
    """(text, url) of every link in Markdown, with the text's emphasis marks removed."""
    return [(re.sub(r'[*_`]', '', m.group(1)).strip(), m.group(2)) for m in re.finditer(r'\[([^\]]*)\]\(([^)\s]+)\)', markdown)]


def title(markdown):
    """The page's first top-level heading."""
    m = re.search(r'^#\s+(.+)$', markdown, re.M)
    return m.group(1).strip() if m else None


def section(markdown, heading):
    """The text under a heading, which is either a Markdown heading ("## File information") or a line of bold text
    ("**File information**"), up to the next heading of either kind; None if there's no such heading."""
    is_heading = lambda line: re.match(r'^\s*#{1,6}\s', line) or re.match(r'^\s*\*\*[^*]+\*\*\s*:?\s*$', line)
    lines = markdown.splitlines()
    for i, line in enumerate(lines):
        if is_heading(line) and re.sub(r'[#*:\s]+', ' ', line).strip().lower() == heading.lower():
            body = []
            for following in lines[i + 1:]:
                if is_heading(following):
                    break
                body.append(following)
            return '\n'.join(body)
    return None
