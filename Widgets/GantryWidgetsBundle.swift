import WidgetKit
import SwiftUI

@main
struct GantryWidgetsBundle: WidgetBundle {
    var body: some Widget {
        FleetHealthWidget()
        AppleServicesControl()
        FavoriteContainerControl()
    }
}
