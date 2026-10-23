import SwiftUI

// MARK: - Stars

/// A rating shown as stars. Read to VoiceOver as one value.
struct StarsView: View {
    let rating: Int
    var font: Font = .subheadline

    var body: some View {
        HStack(spacing: Space.xxs) {
            ForEach(ReviewRules.ratings, id: \.self) { star in
                Image(systemName: star <= rating ? "star.fill" : "star")
                    .foregroundStyle(star <= rating ? Color.slateStar : Color.secondary.opacity(0.5))
            }
        }
        .font(font)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(rating) out of 5 stars")
    }
}

/// Five stars to tap. One adjustable element for VoiceOver (swipe up or down to change the rating).
struct StarRatingInput: View {
    @Binding var rating: Int

    var body: some View {
        HStack(spacing: Space.xs) {
            ForEach(ReviewRules.ratings, id: \.self) { star in
                Button {
                    rating = star
                } label: {
                    Image(systemName: star <= rating ? "star.fill" : "star")
                        .font(.title)
                        .foregroundStyle(star <= rating ? Color.slateStar : Color.secondary)
                        .frame(minWidth: Metrics.minTapTarget, minHeight: Metrics.minTapTarget)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityHidden(true)
            }
        }
        .frame(maxWidth: .infinity)
        .motionSafe(.slateSnappy, value: rating)
        .sensoryFeedback(.selection, trigger: rating)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Rating")
        .accessibilityValue(rating == 0 ? "Not rated" : "\(rating) out of 5 stars")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: rating = min(rating + 1, ReviewRules.ratings.upperBound)
            case .decrement: rating = max(rating - 1, ReviewRules.ratings.lowerBound)
            @unknown default: break
            }
        }
    }
}

// MARK: - One review

struct ReviewCard: View {
    let review: Review
    /// Whether to name the package ("Wedding day"), as a creator's page does.
    var showsPackage = true

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            AdaptiveStack(spacing: Space.s) {
                StarsView(rating: review.rating)
                Spacer(minLength: Space.s)
                Text(review.createdAt.formatted(date: .abbreviated, time: .omitted))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            if !review.body.isEmpty {
                Text(review.body).font(.body)
            }
            Text(attribution)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private var attribution: String {
        let package = review.packageName.trimmingCharacters(in: .whitespacesAndNewlines)
        return showsPackage && !package.isEmpty ? "\(review.reviewerName) · \(package)" : review.reviewerName
    }
}

// MARK: - On a creator's page

/// A creator's reviews, with how they add up. Nothing shows until there is one (a creator sees a hint instead).
struct ReviewsSection: View {
    @Environment(AppModel.self) private var model

    let creatorID: UUID
    var isOwner = false

    @State private var isLoadingMore = false

    var body: some View {
        let summary = model.reviewSummary(for: creatorID)
        let reviews = model.reviews(for: creatorID)

        Group {
            if summary.count > 0 || !reviews.isEmpty {
                VStack(alignment: .leading, spacing: Space.m) {
                    SectionHeader(title: "Reviews") {
                        if let average = summary.average {
                            HStack(spacing: Space.xs) {
                                Image(systemName: "star.fill").foregroundStyle(Color.slateStar)
                                Text(average.formatted(.number.precision(.fractionLength(1)))).monospacedDigit()
                            }
                            .font(.headline)
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel(summary.accessibilityText)
                        }
                    }
                    ForEach(reviews) { review in
                        ReviewCard(review: review).card()
                    }
                    if reviews.count < summary.count {
                        Button {
                            Task {
                                isLoadingMore = true
                                await model.loadMoreReviews(for: creatorID)
                                isLoadingMore = false
                            }
                        } label: {
                            Group {
                                if isLoadingMore { ProgressView() } else { Text("Show more reviews") }
                            }
                            .frame(maxWidth: .infinity, minHeight: Metrics.minTapTarget)
                        }
                        .buttonStyle(.slateOutline)
                        .disabled(isLoadingMore)
                    }
                }
            } else if isOwner {
                VStack(alignment: .leading, spacing: Space.s) {
                    SectionHeader("Reviews")
                    Text("Clients can review a booking once they've confirmed their final files and paid. Reviews show here.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 80)
                        .card(.outlined)
                }
            }
        }
        .task(id: creatorID) { await model.loadReviews(for: creatorID) }
    }
}

// MARK: - On a booking

/// The review on a booking: a prompt for the client to leave one, or the review itself.
struct ReviewSection: View {
    @Environment(AppModel.self) private var model

    let booking: Booking

    @State private var showSheet = false
    @State private var postedCount = 0

    var body: some View {
        if let review = model.review(for: booking) {
            Section {
                ReviewCard(review: review, showsPackage: false)
                    .padding(.vertical, Space.xs)
            } header: {
                Text(booking.clientID == model.session?.userID ? "Your review" : "Review")
            }
                .listRowBackground(Color.slateCard)
        } else if model.canReview(booking) {
            Section {
                Button {
                    showSheet = true
                } label: {
                    Label("Leave a review", systemImage: "star")
                        .frame(minHeight: Metrics.minTapTarget, alignment: .leading)
                }
                .sheet(isPresented: $showSheet) {
                    ReviewSheet(booking: booking) { postedCount += 1 }
                }
                .sensoryFeedback(.success, trigger: postedCount)
            } header: {
                Text("Review")
            } footer: {
                Text("How was it with \(booking.creatorName)? Your review shows on their page.")
            }
                .listRowBackground(Color.slateCard)
        }
    }
}

/// Stars and a few words. Posted once; it can't be edited afterwards.
struct ReviewSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    let booking: Booking
    var onPosted: () -> Void = {}

    @State private var rating = 0
    @State private var text = ""
    @State private var isPosting = false

    private var tooLong: Bool { ReviewRules.remaining(in: text) < 0 }
    private var canPost: Bool { ReviewRules.ratings.contains(rating) && !tooLong && !isPosting }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    StarRatingInput(rating: $rating)
                        .padding(.vertical, Space.xs)
                } header: {
                    Text("Your rating")
                }
                    .listRowBackground(Color.slateCard)

                Section {
                    TextField("What was it like to work with \(booking.creatorName)?", text: $text, axis: .vertical)
                        .lineLimit(4...10)
                } header: {
                    Text("Your review (optional)")
                } footer: {
                    if tooLong {
                        Text("Reviews can be up to \(ReviewRules.maxLength.formatted()) characters.").foregroundStyle(Color.slateDanger)
                    } else if ReviewRules.remaining(in: text) < 100 {
                        Text("\(ReviewRules.remaining(in: text)) characters left")
                    }
                }
                    .listRowBackground(Color.slateCard)

                Section {
                    Label("It shows as \(ReviewRules.displayName(for: booking.clientName)), with the package you booked. You can't change it after posting.",
                          systemImage: "person.crop.circle")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                    .listRowBackground(Color.slateCard)
            }
            .scrollContentBackground(.hidden)
            .slatePageBackground()
            .navigationTitle("Review")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isPosting {
                        ProgressView()
                    } else {
                        Button("Post") { Task { await post() } }
                            .disabled(!canPost)
                    }
                }
            }
            .interactiveDismissDisabled(isPosting)
        }
        .presentationDetents([.large])
    }

    private func post() async {
        isPosting = true
        let posted = await model.submitReview(for: booking, rating: rating, body: text)
        isPosting = false
        if posted {
            onPosted()
            dismiss()
        }
    }
}
