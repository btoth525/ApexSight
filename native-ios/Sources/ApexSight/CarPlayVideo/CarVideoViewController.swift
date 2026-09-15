import AVFoundation
import Combine
import UIKit

/// The full-screen video surface for the CarPlay window (navigation entitlement) and the CarPlay
/// dashboard. A canvas, a spinner and one status line — never a bare black screen.
@MainActor
final class CarVideoViewController: UIViewController {
    let canvas = VideoCanvasView()
    private let status = UILabel()
    private let spinner = UIActivityIndicatorView(style: .large)
    private var fill = false
    private var stateSub: AnyCancellable?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        canvas.frame = view.bounds
        canvas.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(canvas)

        spinner.color = .white
        spinner.hidesWhenStopped = true
        spinner.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(spinner)

        status.textColor = .white
        status.font = .systemFont(ofSize: 22, weight: .medium)
        status.textAlignment = .center
        status.numberOfLines = 2
        status.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(status)

        NSLayoutConstraint.activate([
            spinner.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            status.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            status.topAnchor.constraint(equalTo: spinner.bottomAnchor, constant: 16),
            status.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 24),
            status.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -24)
        ])

        stateSub = CarVideoSession.shared.$state
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in self?.render(state) }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        CarVideoSession.shared.attach(canvas)
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        CarVideoSession.shared.detach(canvas)
    }

    func toggleFill() {
        fill.toggle()
        canvas.setGravity(fill ? .resizeAspectFill : .resizeAspect)
    }

    private func render(_ state: CarVideoSession.State) {
        switch state {
        case .idle:
            spinner.stopAnimating()
            status.text = "Choose a feed or Mirror"
        case .connecting:
            spinner.startAnimating()
            status.text = "Starting video…"
        case .streaming:
            spinner.stopAnimating()
            status.text = ""
        case .failed(let message):
            spinner.stopAnimating()
            status.text = "Offline — \(message)"
        }
    }
}
