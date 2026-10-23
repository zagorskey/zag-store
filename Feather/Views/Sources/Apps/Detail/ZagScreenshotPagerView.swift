//
//  ZagScreenshotPagerView.swift
//  Feather
//
//  Stable, reusable UIKit pages for the fullscreen screenshot viewer.
//  Unlike SwiftUI PageTabViewStyle, UICollectionView does not rebuild or
//  remeasure the page hierarchy when the displayed UIImage changes.
//

import SwiftUI
import UIKit

struct ZagScreenshotPagerView: UIViewRepresentable {
    @Binding var selectedIndex: Int
    let urls: [URL]
    let thumbnails: [URL: UIImage]
    let previews: [URL: UIImage]

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIView(context: Context) -> ZagScreenshotPagingCollection {
        let pager = ZagScreenshotPagingCollection()
        pager.collectionView.dataSource = context.coordinator
        pager.collectionView.delegate = context.coordinator
        context.coordinator.pager = pager
        context.coordinator.parent = self
        pager.onLayout = { [weak coordinator = context.coordinator] in
            coordinator?.alignInitialPage()
        }
        return pager
    }

    func updateUIView(_ uiView: ZagScreenshotPagingCollection, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self

        // The URL sequence remains stable for the viewer's lifetime. Never
        // reload the collection because an image finished downloading.
        if coordinator.displayedURLs != urls {
            coordinator.displayedURLs = urls
            coordinator.hasAlignedInitialPage = false
            uiView.collectionView.reloadData()
        }

        coordinator.updateVisibleImages()

        // A user's swipe updates the Binding through the delegate below.
        // Do not programmatically scroll back while a gesture is in flight.
        if !uiView.collectionView.isDragging &&
           !uiView.collectionView.isDecelerating &&
           coordinator.currentPage != selectedIndex {
            coordinator.scrollTo(index: selectedIndex)
        }
    }

    final class Coordinator: NSObject, UICollectionViewDataSource, UICollectionViewDelegate, UIScrollViewDelegate {
        var parent: ZagScreenshotPagerView
        weak var pager: ZagScreenshotPagingCollection?
        var displayedURLs: [URL] = []
        var currentPage: Int = 0
        var hasAlignedInitialPage = false

        init(parent: ZagScreenshotPagerView) {
            self.parent = parent
            self.currentPage = parent.selectedIndex
        }

        func collectionView(
            _ collectionView: UICollectionView,
            numberOfItemsInSection section: Int
        ) -> Int {
            displayedURLs.count
        }

        func collectionView(
            _ collectionView: UICollectionView,
            cellForItemAt indexPath: IndexPath
        ) -> UICollectionViewCell {
            guard let cell = collectionView.dequeueReusableCell(
                withReuseIdentifier: ZagScreenshotPageCell.reuseID,
                for: indexPath
            ) as? ZagScreenshotPageCell else {
                return UICollectionViewCell()
            }
            configure(cell, at: indexPath.item)
            return cell
        }

        func collectionView(
            _ collectionView: UICollectionView,
            willDisplay cell: UICollectionViewCell,
            forItemAt indexPath: IndexPath
        ) {
            if let cell = cell as? ZagScreenshotPageCell {
                configure(cell, at: indexPath.item)
            }
        }

        func configure(_ cell: ZagScreenshotPageCell, at index: Int) {
            guard displayedURLs.indices.contains(index) else { return }
            let url = displayedURLs[index]
            cell.configure(
                url: url,
                image: parent.previews[url] ?? parent.thumbnails[url]
            )
        }

        func updateVisibleImages() {
            guard let collection = pager?.collectionView else { return }
            for case let cell as ZagScreenshotPageCell in collection.visibleCells {
                guard let indexPath = collection.indexPath(for: cell) else { continue }
                configure(cell, at: indexPath.item)
            }
        }

        func alignInitialPage() {
            guard !hasAlignedInitialPage,
                  let collection = pager?.collectionView,
                  collection.bounds.width > 0,
                  !displayedURLs.isEmpty else { return }
            hasAlignedInitialPage = true
            scrollTo(index: parent.selectedIndex)
        }

        func scrollTo(index: Int) {
            guard let collection = pager?.collectionView,
                  displayedURLs.indices.contains(index),
                  collection.bounds.width > 0 else { return }
            currentPage = index
            collection.setContentOffset(
                CGPoint(x: CGFloat(index) * collection.bounds.width, y: 0),
                animated: false
            )
        }

        func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
            settle(scrollView)
        }

        func scrollViewDidEndDragging(
            _ scrollView: UIScrollView,
            willDecelerate decelerate: Bool
        ) {
            if !decelerate { settle(scrollView) }
        }

        func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) {
            settle(scrollView)
        }

        private func settle(_ scrollView: UIScrollView) {
            guard scrollView.bounds.width > 0, !displayedURLs.isEmpty else { return }
            let index = max(
                0,
                min(
                    displayedURLs.count - 1,
                    Int((scrollView.contentOffset.x / scrollView.bounds.width).rounded())
                )
            )
            currentPage = index
            if parent.selectedIndex != index {
                parent.selectedIndex = index
            }
        }
    }
}

// Explicit viewport-sized cells, zero inter-item spacing, and paging
// preserve perfectly centered screenshots irrespective of aspect ratio.
final class ZagScreenshotPagingCollection: UIView {
    let collectionView: UICollectionView
    var onLayout: (() -> Void)?
    private var previousSize: CGSize = .zero

    override init(frame: CGRect) {
        let layout = UICollectionViewFlowLayout()
        layout.scrollDirection = .horizontal
        layout.minimumLineSpacing = 0
        layout.minimumInteritemSpacing = 0
        collectionView = UICollectionView(frame: .zero, collectionViewLayout: layout)
        super.init(frame: frame)

        collectionView.translatesAutoresizingMaskIntoConstraints = false
        collectionView.isPagingEnabled = true
        collectionView.showsHorizontalScrollIndicator = false
        collectionView.alwaysBounceHorizontal = false
        collectionView.contentInsetAdjustmentBehavior = .never
        collectionView.backgroundColor = .clear
        collectionView.register(
            ZagScreenshotPageCell.self,
            forCellWithReuseIdentifier: ZagScreenshotPageCell.reuseID
        )
        addSubview(collectionView)
        NSLayoutConstraint.activate([
            collectionView.leadingAnchor.constraint(equalTo: leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: trailingAnchor),
            collectionView.topAnchor.constraint(equalTo: topAnchor),
            collectionView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let size = collectionView.bounds.size
        guard size.width > 0, size.height > 0 else { return }
        if size != previousSize {
            let oldWidth = previousSize.width
            let currentPage = oldWidth > 0
                ? Int((collectionView.contentOffset.x / oldWidth).rounded())
                : 0
            previousSize = size
            if let layout = collectionView.collectionViewLayout as? UICollectionViewFlowLayout {
                layout.itemSize = size
                layout.invalidateLayout()
            }
            if oldWidth > 0 {
                collectionView.setContentOffset(
                    CGPoint(x: CGFloat(currentPage) * size.width, y: 0),
                    animated: false
                )
            }
        }
        onLayout?()
    }
}

final class ZagScreenshotPageCell: UICollectionViewCell {
    static let reuseID = "ZagScreenshotPageCell"

    // A calm, inset card lets both light and dark screenshots look at home
    // without adding shadows, blur effects, or layers over the scrolling view.
    private let cardView = UIView()
    private let imageView = UIImageView()
    private let spinner = UIActivityIndicatorView(style: .medium)
    private var representedURL: URL?
    private var fallbackTask: Task<Void, Never>?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        contentView.backgroundColor = .clear

        cardView.translatesAutoresizingMaskIntoConstraints = false
        cardView.backgroundColor = UIColor.secondarySystemGroupedBackground.withAlphaComponent(0.40)
        cardView.layer.cornerRadius = 22
        cardView.layer.cornerCurve = .continuous
        cardView.layer.borderWidth = 0.5
        cardView.layer.borderColor = UIColor.separator.withAlphaComponent(0.24).cgColor
        contentView.addSubview(cardView)

        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.contentMode = .scaleAspectFit
        imageView.clipsToBounds = true
        imageView.layer.cornerRadius = 22
        imageView.layer.cornerCurve = .continuous
        cardView.addSubview(imageView)

        spinner.translatesAutoresizingMaskIntoConstraints = false
        spinner.color = .secondaryLabel
        cardView.addSubview(spinner)

        NSLayoutConstraint.activate([
            cardView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            cardView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            cardView.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 6),
            cardView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -6),
            imageView.leadingAnchor.constraint(equalTo: cardView.leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: cardView.trailingAnchor),
            imageView.topAnchor.constraint(equalTo: cardView.topAnchor),
            imageView.bottomAnchor.constraint(equalTo: cardView.bottomAnchor),
            spinner.centerXAnchor.constraint(equalTo: cardView.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: cardView.centerYAnchor)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        fallbackTask?.cancel()
        fallbackTask = nil
        representedURL = nil
        imageView.image = nil
        spinner.stopAnimating()
    }

    func configure(url: URL, image: UIImage?) {
        if representedURL != url {
            fallbackTask?.cancel()
            fallbackTask = nil
            representedURL = url
            imageView.image = nil
        }
        if let image {
            if imageView.image !== image {
                imageView.image = image
            }
            spinner.stopAnimating()
            fallbackTask?.cancel()
            fallbackTask = nil
            return
        }
        if imageView.image != nil || fallbackTask != nil { return }
        spinner.startAnimating()

        // Gallery thumbnails may not have finished when the viewer opens.
        // Fetch only for on-screen cells and decode on a background task.
        fallbackTask = Task { [weak self] in
            let bytes = await ZagFeaturedImageCache.shared.load(url)
            guard !Task.isCancelled, let bytes else { return }
            let data = bytes.data
            let decoded = await Task.detached(priority: .utility) {
                ZagScreenshotThumbnailDecoder.decode(data, maxPixelSize: 1200)
            }.value
            guard !Task.isCancelled, let self, self.representedURL == url else { return }
            self.imageView.image = decoded
            self.spinner.stopAnimating()
            self.fallbackTask = nil
        }
    }

    deinit {
        fallbackTask?.cancel()
    }
}
