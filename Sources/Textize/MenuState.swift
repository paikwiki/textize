import Combine
import Foundation

/// 메뉴바 메뉴가 관찰하는 최소 상태. 자막 내용과 분리해 두어야
/// 자막이 갱신될 때마다 메뉴가 다시 만들어지며 하위 메뉴가 닫히는 일이 없다.
@MainActor
final class MenuState: ObservableObject {
    @Published var isRunning = false
    @Published var isSelecting = false
    @Published var isOverlayHidden = false
    @Published var isAutoHidden = false

    private var cancellables: Set<AnyCancellable> = []

    func bind(to model: CaptionModel) {
        model.$isRunning.removeDuplicates()
            .sink { [weak self] v in self?.isRunning = v }
            .store(in: &cancellables)
        model.$isSelecting.removeDuplicates()
            .sink { [weak self] v in self?.isSelecting = v }
            .store(in: &cancellables)
        model.$isOverlayHidden.removeDuplicates()
            .sink { [weak self] v in self?.isOverlayHidden = v }
            .store(in: &cancellables)
        model.$isAutoHidden.removeDuplicates()
            .sink { [weak self] v in self?.isAutoHidden = v }
            .store(in: &cancellables)
    }
}
