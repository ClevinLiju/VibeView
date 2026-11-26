import SwiftUI
import MolCore
import MolIO

/// Gallery entries (VIBEVIEW_GALLERY=1) for the element picker with groups, the Z-Matrix tab and From Z-Matrix.
@MainActor
enum PortedPanelsGallery {
    static func entries(editor: EditorModel) -> [UIGallery.Entry] {
        let ethanol = (try? ZMatrixText.parse("""
        0 1
        C
        C  1  1.52
        O  2  1.43  1  109.5
        H  3  0.96  2  108.0  1  180.0
        H  1  1.09  2  110.0  3   60.0
        H  1  1.09  2  110.0  3  180.0
        H  1  1.09  2  110.0  3  -60.0
        H  2  1.09  1  110.0  3  120.0
        H  2  1.09  1  110.0  3 -120.0
        """).molecule) ?? Molecule()
        let zm = EditorModel(molecule: ethanol)
        zm.molecule.title = "ethanol"
        zm.selection = [2]
        let picker = EditorModel()
        picker.payload = .group("C.carboxyl")
        return [
            ("element-picker-carbon", CGSize(width: 660, height: 720),
             AnyView(PeriodicTablePopover(editor: picker, isPresented: .constant(true), initialElement: 6))),
            ("element-picker-nitrogen", CGSize(width: 660, height: 640),
             AnyView(PeriodicTablePopover(editor: picker, isPresented: .constant(true), initialElement: 7))),
            ("sidebar-groups-oxygen", CGSize(width: 560, height: 260),
             AnyView(ElementGroupPicker(editor: picker, z: 8).padding(12))),
            ("zmatrix-table", CGSize(width: 760, height: 300), AnyView(ZMatrixView(editor: zm))),
            ("zmatrix-text", CGSize(width: 760, height: 300), AnyView(ZMatrixView(editor: zm, showText: true, style: .gaussianVariables))),
            ("from-zmatrix", CGSize(width: 600, height: 420), AnyView(FromZMatrixSheet(editor: zm))),
            ("calc-setup-catalog", CGSize(width: 900, height: 700), AnyView(CalcSetupSheet(editor: zm))),
        ]
    }
}
