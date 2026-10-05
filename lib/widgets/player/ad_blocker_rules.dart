import 'package:flutter_inappwebview/flutter_inappwebview.dart';

class AdBlockerRules {
  AdBlockerRules._();

  /// Regex pattern of known ad networks, trackers, popups, and betting redirects
  static const List<String> adDomainFilters = [
    r'.*(doubleclick|googlesyndication|googleadservices).*',
    r'.*(popads|popcash|popunder|onclick).*',
    r'.*(propellerads|hilltopads|monetag|adsterra).*',
    r'.*(exoclick|trafficjunky|juicyads).*',
    r'.*(adnxs|adroll|outbrain|taboola|mgid|zergnet).*',
    r'.*(bet365|1xbet|betway|parimatch|mostbet).*',
    r'.*(redirect|track|affiliate|advert|banner).*',
    r'.*(syndication|clicksor|alwingulla|whomever).*',
  ];

  /// Declarative content blockers for InAppWebView
  static List<ContentBlocker> getContentBlockers() {
    return adDomainFilters.map((pattern) {
      return ContentBlocker(
        trigger: ContentBlockerTrigger(
          urlFilter: pattern,
        ),
        action: ContentBlockerAction(
          type: ContentBlockerActionType.BLOCK,
        ),
      );
    }).toList();
  }

  /// JavaScript injected at the very start of page evaluation to disable
  /// popups, click-jacking transparent overlays, and window.open redirects.
  static const String antiAdScript = """
    (function() {
      // 1. Disable window.open popup hijacking
      window.open = function(url, target, features) {
        console.log('[AdBlock] Blocked window.open:', url);
        return null;
      };

      // 2. Prevent alerts / prompts from scam banners
      window.alert = function() { return false; };
      window.confirm = function() { return false; };

      // 3. Remove invisible clickjack overlays
      function removeClickjackOverlays() {
        try {
          var allElements = document.querySelectorAll('div, a, iframe');
          allElements.forEach(function(el) {
            var style = window.getComputedStyle(el);
            var zIndex = parseInt(style.zIndex, 10);
            var opacity = parseFloat(style.opacity);
            // Detect full-screen invisible or fixed overlays
            if ((zIndex > 1000 || style.position === 'fixed') && opacity < 0.1 && el.tagName === 'A') {
              el.remove();
            }
          });
        } catch(e) {}
      }

      document.addEventListener('DOMContentLoaded', removeClickjackOverlays);
      setInterval(removeClickjackOverlays, 1500);
    })();
  """;
}
