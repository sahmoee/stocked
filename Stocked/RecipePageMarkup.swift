import Foundation

/// Foundation-only, bounded helpers shared by browser snapshots and network imports.
/// No attributed-string HTML rendering (which can synchronously hop to the main thread).
nonisolated enum RecipePageMarkup {
  static func text(_ value: String) -> String {
    let stripped = value.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
    let named = [
      "amp": "&", "quot": "\"", "apos": "'", "nbsp": " ", "lt": "<", "gt": ">",
      "frac12": "½", "frac14": "¼", "frac34": "¾", "ndash": "–", "mdash": "—", "rsquo": "’",
      "lsquo": "‘",
    ]
    guard let regex = try? NSRegularExpression(pattern: #"&(#x[0-9a-fA-F]+|#[0-9]+|[a-zA-Z]+);"#)
    else { return stripped }
    var result = ""
    var end = stripped.startIndex
    for match in regex.matches(in: stripped, range: NSRange(stripped.startIndex..., in: stripped)) {
      guard let range = Range(match.range, in: stripped),
        let inner = Range(match.range(at: 1), in: stripped)
      else { continue }
      result += stripped[end..<range.lowerBound]
      let entity = String(stripped[inner])
      let number: UInt32?
      if entity.hasPrefix("#x") {
        number = UInt32(entity.dropFirst(2), radix: 16)
      } else if entity.hasPrefix("#") {
        number = UInt32(entity.dropFirst())
      } else {
        number = nil
      }
      let scalar = number.flatMap(UnicodeScalar.init).flatMap {
        CharacterSet.controlCharacters.contains($0) ? nil : String($0)
      }
      result += scalar ?? named[entity] ?? String(stripped[range])
      end = range.upperBound
    }
    result += stripped[end...]
    return result.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  static func imageURL(_ raw: String, pageURL: String) -> String {
    guard !raw.isEmpty, let base = RecipeBrowserPolicy.url(pageURL),
      let resolved = URL(string: text(raw), relativeTo: base)?.absoluteURL,
      let safe = RecipeBrowserPolicy.url(resolved.absoluteString)
    else { return "" }
    return safe.absoluteString
  }

  /// Only explicit serving counts: cookie/loaf yields and ranges need review.
  static func servings(_ raw: String) -> Int? {
    let value = text(raw).lowercased()
    guard
      let range = value.range(
        of: #"^(?:serves\s+)?([0-9]{1,2})(?:\s+(?:servings?|people|persons?))?$"#,
        options: .regularExpression)
    else { return nil }
    let digits = value[range].filter(\.isNumber)
    guard let count = Int(digits), (1...50).contains(count) else { return nil }
    return count
  }

  /// Read only structured recipe blocks on explicit Import, never the full DOM,
  /// cookies, storage or hidden form values. Size limits apply before crossing IPC.
  static let snapshotScript = #"""
    (() => {
      let html = '', bytes = 0, count = 0, inspected = 0;
      for (const node of document.querySelectorAll('script[type="application/ld+json"]')) {
        if (count >= 16 || inspected++ >= 32) break;
        const value = node.textContent || '';
        if (value.length > 262144 || bytes + value.length > 524288) continue;
        html += '<script type="application/ld+json">' + value + '</script>';
        bytes += value.length; count++;
      }
      return { url: location.href, html: html };
    })()
    """#

  /// Existing recipe-card anchors only; no invented anchor, reformatting, ad
  /// removal or scrolling animation. Called by the user, never on a timer.
  static let jumpScript = #"""
    (() => {
      const node = document.querySelector('[id^="wprm-recipe-container"], .tasty-recipes, .recipe-card, [itemtype$="/Recipe"], [id^="recipe-card"], #recipe');
      if (!node) return false;
      node.scrollIntoView({behavior: 'instant', block: 'start'});
      return true;
    })()
    """#
}
