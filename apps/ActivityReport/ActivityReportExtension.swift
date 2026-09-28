import DeviceActivity
import ExtensionKit
import SwiftUI

@main
struct ActivityReportExtension: DeviceActivityReportExtension {
    var body: some DeviceActivityReportScene {
        SnapshotReport { configuration in
            SnapshotReportView(configuration: configuration)
        }
    }
}
