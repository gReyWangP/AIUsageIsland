import SwiftUI

extension View {
    func settingsCard() -> some View {
        self.padding(12)
            .frame(maxWidth:.infinity,alignment:.leading)
            .background(.primary.opacity(0.035),in:RoundedRectangle(cornerRadius:12))
            .overlay(RoundedRectangle(cornerRadius:12).strokeBorder(.primary.opacity(0.055),lineWidth:1).allowsHitTesting(false))
            .disclosureGroupStyle(SettingsDisclosureGroupStyle())
    }
}
