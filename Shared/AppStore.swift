// SideLinker App Store identity used by the fork's update/review deep links.
// This numeric listing ID does not imply that the GPL receiver target shares
// the proprietary SideLinker app's bundle identifier or distribution model.

import Foundation

enum AppStore {
    static let iOSAppID = "6760007015"
    static let updateURL = URL(string: "itms-apps://apps.apple.com/app/id\(iOSAppID)")!
    static let webURL = URL(string: "https://apps.apple.com/cn/app/sidelinker/id6760007015")!
    static let reviewURL = URL(string: "https://apps.apple.com/app/id\(iOSAppID)?action=write-review")!
}
