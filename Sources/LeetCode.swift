import Foundation

/// Website exceptions are host names, never URL substrings.
func websiteHost(_ input: String) -> String? {
    let text = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard !text.isEmpty,
          let url = URLComponents(string: text.contains("://") ? text : "https://" + text),
          ["http", "https"].contains(url.scheme ?? ""), url.user == nil, url.password == nil,
          let raw = url.host, raw.contains("."), !raw.contains(".."),
          raw.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "-") }) else { return nil }
    let host = raw.hasSuffix(".") ? String(raw.dropLast()) : raw
    return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
}

func websiteAllowed(_ url: String, hosts: Set<String>) -> Bool {
    guard let host = websiteHost(url) else { return false }
    return hosts.contains { host == $0 || host.hasSuffix("." + $0) }
}

func leetCodeProblem(_ url: String) -> String? {
    guard let c = URLComponents(string: url), c.scheme == "https",
          ["leetcode.com", "www.leetcode.com"].contains(c.host?.lowercased() ?? "") else { return nil }
    let path = c.path.split(separator: "/")
    guard path.count >= 2, path[0] == "problems",
          path[1].allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }) else { return nil }
    return String(path[1])
}

struct LeetCodeSubmission: Decodable {
    let status_display: String
    let timestamp: String
}

func leetCodeAccepted(_ json: String, since: Date) -> Bool {
    guard let data = json.data(using: .utf8),
          let submissions = try? JSONDecoder().decode([LeetCodeSubmission].self, from: data) else { return false }
    return submissions.contains {
        $0.status_display == "Accepted" && (Double($0.timestamp) ?? 0) > since.timeIntervalSince1970
    }
}

/// Read the signed-in user's problem-specific submission history. Apple Events don't await
/// promises, so cache the async result in the page and collect it on the next tick.
func leetCodeJS(problem: String) -> String {
    """
    (function(){
      if(location.hostname!=='leetcode.com' && location.hostname!=='www.leetcode.com')return 'error';
      var key=\(jsString(problem));
      var s=window.__lectureLockSubmissions;
      if(!s || s.key!==key)s=window.__lectureLockSubmissions={key:key,value:'pending',at:0,busy:false};
      if(!s.busy && Date.now()-s.at>10000){
        s.busy=true;s.at=Date.now();
        fetch('/api/submissions/'+encodeURIComponent(key)+'/?offset=0&limit=20',
          {credentials:'same-origin',cache:'no-store',signal:AbortSignal.timeout(8000)})
          .then(function(r){if(!r.ok)throw Error();return r.json()})
          .then(function(r){if(!Array.isArray(r.submissions_dump))throw Error();s.value=JSON.stringify(r.submissions_dump)})
          .catch(function(){s.value='error'})
          .finally(function(){s.busy=false});
      }
      return s.value;
    })()
    """
}
