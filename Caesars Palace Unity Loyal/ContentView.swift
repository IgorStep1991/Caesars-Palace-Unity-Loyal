import SwiftUI
import Combine
import PhotosUI
import UIKit

struct ContentView: View {
    @StateObject private var store = LoyaltyStore()

    var body: some View {
        Group {
            if store.session.isAuthenticated {
                MainShellView()
                    .environmentObject(store)
            } else {
                AuthenticationView()
                    .environmentObject(store)
            }
        }
        .tint(Color.caesarsRed)
    }
}

enum AppTab: Hashable {
    case profile
    case scrolls
    case events
    case games
    case challenges
    case settings
}

enum LocalAccountCredentials {
    static let email = "reviewer@caesars.local"
    static let password = "caesars1"
}

struct MainShellView: View {
    @State private var selectedTab: AppTab = .profile

    var body: some View {
        TabView(selection: $selectedTab) {
            NavigationStack {
                ProfileHubView(selectedTab: $selectedTab)
            }
            .tabItem { Label("Profile", systemImage: "person.crop.circle") }
            .tag(AppTab.profile)

            NavigationStack {
                ScrollsView()
            }
            .tabItem { Label("Scrolls", systemImage: "scroll") }
            .tag(AppTab.scrolls)

            NavigationStack {
                EventsView()
            }
            .tabItem { Label("Calendar", systemImage: "calendar") }
            .tag(AppTab.events)

            NavigationStack {
                GameLibraryView()
            }
            .tabItem { Label("Games", systemImage: "books.vertical") }
            .tag(AppTab.games)

            NavigationStack {
                ChallengesView()
            }
            .tabItem { Label("Challenges", systemImage: "shield.lefthalf.filled") }
            .tag(AppTab.challenges)

            NavigationStack {
                SettingsView()
            }
            .tabItem { Label("Settings", systemImage: "gearshape") }
            .tag(AppTab.settings)
        }
    }
}

@MainActor
final class LoyaltyStore: ObservableObject {
    @Published var session: SessionState
    @Published var rewards: [RewardScroll]
    @Published var registeredEventIDs: Set<String>
    @Published var challenges: [LoyaltyChallenge]
    @Published var notificationSettings: NotificationSettings

    let events: [LoyaltyEvent]
    let games: [CasinoGuide]

    private let storage = LocalStorage()

    init() {
        let snapshot = storage.load()
        session = snapshot.session
        rewards = snapshot.rewards.isEmpty ? RewardScroll.seed : snapshot.rewards
        registeredEventIDs = snapshot.registeredEventIDs
        challenges = snapshot.challenges.isEmpty ? LoyaltyChallenge.seed : snapshot.challenges
        notificationSettings = snapshot.notificationSettings
        events = LoyaltyEvent.seed
        games = CasinoGuide.seed
    }

    func signIn(email: String, password: String) async throws {
        try await Task.sleep(nanoseconds: 1_100_000_000)
        let trimmedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedEmail.isEmpty else {
            throw AppError.validation("Enter your email address.")
        }
        guard !password.isEmpty else {
            throw AppError.validation("Enter your password.")
        }
        let expectedEmail = session.profile.email.isEmpty ? LocalAccountCredentials.email : session.profile.email
        guard trimmedEmail.caseInsensitiveCompare(expectedEmail) == .orderedSame else {
            throw AppError.validation("Use the local reviewer account email.")
        }
        guard password == session.password else {
            throw AppError.validation("The password is incorrect.")
        }
        if session.profile.email.isEmpty {
            session.profile.email = LocalAccountCredentials.email
        }
        session.isAuthenticated = true
        persist()
    }

    func signOut() {
        session.isAuthenticated = false
        persist()
    }

    func deleteAccount() {
        session = SessionState()
        rewards = RewardScroll.seed
        registeredEventIDs = []
        challenges = LoyaltyChallenge.seed
        notificationSettings = NotificationSettings()
        persist()
    }

    func changeDisplayName(_ name: String) throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else {
            throw AppError.validation("Name must contain at least 2 characters.")
        }
        session.profile.name = trimmed
        persist()
    }

    func updateAvatarImageData(_ data: Data?) {
        session.profile.avatarImageData = data
        persist()
    }

    func changePassword(current: String, newPassword: String, confirmation: String) throws {
        guard current == session.password else {
            throw AppError.validation("Current password is incorrect.")
        }
        guard newPassword.count >= 6 else {
            throw AppError.validation("New password must contain at least 6 characters.")
        }
        guard newPassword == confirmation else {
            throw AppError.validation("New password and confirmation do not match.")
        }
        session.password = newPassword
        persist()
   }

    func revealReward(_ reward: RewardScroll) {
        updateReward(reward.id) { item in
            item.isRevealed = true
            item.status = .revealed
            item.revealedAt = Date()
        }
    }

    func activateReward(_ reward: RewardScroll) throws {
        guard reward.isRevealed else {
            throw AppError.validation("Unroll the scroll before activating the reward.")
        }
        guard session.profile.tierCredits >= reward.creditCost else {
            throw AppError.validation("You need \(reward.creditCost.formatted()) tier credits to activate this reward.")
        }
        guard reward.requiredTier == nil || session.profile.status.rank >= (reward.requiredTier?.rank ?? 0) else {
            throw AppError.validation("This reward requires \(reward.requiredTier?.title ?? "a higher") status.")
        }
        session.profile.tierCredits -= reward.creditCost
        session.profile.activatedRewardCount += 1
        updateReward(reward.id) { item in
            item.status = .activated
            item.activatedAt = Date()
        }
    }

    func claimDailyScroll() throws {
        let dailyTitles = Set(["Golden Laurel Bonus", "Colosseum Priority Access", "Chef's Table Invitation"])
        if let lastClaim = rewards.filter({ dailyTitles.contains($0.title) }).map(\.claimedAt).max(),
           Calendar.current.isDateInToday(lastClaim) {
            throw AppError.validation("A new scroll is available once per day. Check back tomorrow.")
        }
        rewards.insert(RewardScroll.daily(), at: 0)
        persist()
    }

    func register(for event: LoyaltyEvent) throws {
        guard session.profile.status.rank >= event.requiredTier.rank else {
            throw AppError.validation("\(event.requiredTier.title) status is required for this event.")
        }
        guard !registeredEventIDs.contains(event.id) else {
            throw AppError.validation("You are already registered for this event.")
        }
        registeredEventIDs.insert(event.id)
        persist()
    }

    func unregister(from event: LoyaltyEvent) {
        registeredEventIDs.remove(event.id)
        persist()
    }

    func addChallengeProgress(_ challenge: LoyaltyChallenge) {
        guard let index = challenges.firstIndex(where: { $0.id == challenge.id }) else { return }
        challenges[index].current = min(challenges[index].target, challenges[index].current + challenges[index].step)
        persist()
    }

    func claimChallenge(_ challenge: LoyaltyChallenge) throws {
        guard let index = challenges.firstIndex(where: { $0.id == challenge.id }) else { return }
        guard challenges[index].current >= challenges[index].target else {
            throw AppError.validation("Complete the challenge before claiming the reward.")
        }
        guard !challenges[index].isClaimed else {
            throw AppError.validation("This challenge reward has already been claimed.")
        }
        challenges[index].isClaimed = true
        session.profile.tierCredits += challenges[index].creditReward
        persist()
    }

    func saveNotifications(_ settings: NotificationSettings) {
        notificationSettings = settings
        persist()
    }

    private func updateReward(_ id: UUID, mutation: (inout RewardScroll) -> Void) {
        guard let index = rewards.firstIndex(where: { $0.id == id }) else { return }
        mutation(&rewards[index])
        persist()
    }

    private func persist() {
        storage.save(
            AppSnapshot(
                session: session,
                rewards: rewards,
                registeredEventIDs: registeredEventIDs,
                challenges: challenges,
                notificationSettings: notificationSettings
            )
        )
    }
}

struct SessionState: Codable {
    var isAuthenticated = false
    var profile = UserProfile()
    var password = LocalAccountCredentials.password

    enum CodingKeys: String, CodingKey {
        case isAuthenticated
        case profile
        case password
    }

    init(isAuthenticated: Bool = false, profile: UserProfile = UserProfile(), password: String = LocalAccountCredentials.password) {
        self.isAuthenticated = isAuthenticated
        self.profile = profile
        self.password = password
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        isAuthenticated = try container.decodeIfPresent(Bool.self, forKey: .isAuthenticated) ?? false
        profile = try container.decodeIfPresent(UserProfile.self, forKey: .profile) ?? UserProfile()
        password = try container.decodeIfPresent(String.self, forKey: .password) ?? LocalAccountCredentials.password
    }
}

struct UserProfile: Codable {
    var name = "Unity Member"
    var email = LocalAccountCredentials.email
    var tierCredits = 1_500
    var activatedRewardCount = 0
    var avatarImageData: Data?

    var status: LoyaltyStatus {
        LoyaltyStatus.status(for: tierCredits)
    }

    var nextStatus: LoyaltyStatus? {
        LoyaltyStatus.allCases.first { $0.minimumCredits > tierCredits }
    }

    var progressToNextStatus: Double {
        guard let nextStatus else { return 1 }
        let previous = LoyaltyStatus.allCases.last { $0.minimumCredits <= tierCredits }?.minimumCredits ?? 0
        let span = max(1, nextStatus.minimumCredits - previous)
        return min(1, max(0, Double(tierCredits - previous) / Double(span)))
    }
}

enum LoyaltyStatus: String, Codable, CaseIterable, Identifiable {
    case citizen
    case senator
    case consul
    case emperor

    var id: String { rawValue }

    var title: String {
        switch self {
        case .citizen: "Citizen"
        case .senator: "Senator"
        case .consul: "Consul"
        case .emperor: "Emperor"
        }
    }

    var minimumCredits: Int {
        switch self {
        case .citizen: 0
        case .senator: 2_500
        case .consul: 6_000
        case .emperor: 12_000
        }
    }

    var rank: Int {
        switch self {
        case .citizen: 0
        case .senator: 1
        case .consul: 2
        case .emperor: 3
        }
    }

    var symbol: String {
        switch self {
        case .citizen: "person.fill"
        case .senator: "building.columns.fill"
        case .consul: "crown.fill"
        case .emperor: "diamond.fill"
        }
    }

    var assetName: String {
        switch self {
        case .citizen: "loyal_0"
        case .senator: "loyal_1"
        case .consul: "loyal_2"
        case .emperor: "loyal_3"
        }
    }

    var panelColors: [Color] {
        switch self {
        case .citizen:
            [Color.caesarsRed.opacity(0.92), Color.black.opacity(0.75)]
        case .senator:
            [Color(red: 0.42, green: 0.43, blue: 0.48), Color.caesarsRed.opacity(0.78)]
        case .consul:
            [Color.gold.opacity(0.95), Color.caesarsRed.opacity(0.82)]
        case .emperor:
            [Color(red: 0.13, green: 0.12, blue: 0.18), Color(red: 0.33, green: 0.12, blue: 0.47)]
        }
    }

    static func status(for credits: Int) -> LoyaltyStatus {
        allCases.last { credits >= $0.minimumCredits } ?? .citizen
    }
}

enum RewardStatus: String, Codable {
    case sealed
    case revealed
    case activated
    case expired

    var title: String {
        switch self {
        case .sealed: "Sealed"
        case .revealed: "Ready to activate"
        case .activated: "Activated"
        case .expired: "Expired"
        }
    }
}

struct RewardScroll: Identifiable, Codable, Hashable {
    var id = UUID()
    var title: String
    var description: String
    var creditCost: Int
    var validDays: Int
    var requiredTier: LoyaltyStatus?
    var status: RewardStatus
    var isRevealed: Bool
    var claimedAt: Date
    var revealedAt: Date?
    var activatedAt: Date?

    var expirationDate: Date {
        Calendar.current.date(byAdding: .day, value: validDays, to: claimedAt) ?? claimedAt
    }

    static let seed: [RewardScroll] = [
        RewardScroll(title: "100 Free Spins", description: "Use on the Julius Caesar slot collection.", creditCost: 750, validDays: 14, requiredTier: nil, status: .sealed, isRevealed: false, claimedAt: Date()),
        RewardScroll(title: "Bacchanal Dinner for Two", description: "A dining credit for Bacchanal Buffet.", creditCost: 1_200, validDays: 30, requiredTier: .senator, status: .revealed, isRevealed: true, claimedAt: Date().addingTimeInterval(-86_400 * 2), revealedAt: Date().addingTimeInterval(-86_400), activatedAt: nil),
        RewardScroll(title: "Room Upgrade", description: "Complimentary room upgrade, subject to availability.", creditCost: 2_000, validDays: 60, requiredTier: nil, status: .activated, isRevealed: true, claimedAt: Date().addingTimeInterval(-86_400 * 5), revealedAt: Date().addingTimeInterval(-86_400 * 4), activatedAt: Date().addingTimeInterval(-86_400 * 3))
    ]

    static func daily() -> RewardScroll {
        let pool = [
            RewardScroll(title: "Golden Laurel Bonus", description: "A 250 credit boost after your next eligible visit.", creditCost: 0, validDays: 7, requiredTier: nil, status: .sealed, isRevealed: false, claimedAt: Date()),
            RewardScroll(title: "Colosseum Priority Access", description: "Early window for select show registrations.", creditCost: 1_500, validDays: 21, requiredTier: .senator, status: .sealed, isRevealed: false, claimedAt: Date()),
            RewardScroll(title: "Chef's Table Invitation", description: "Request an invite to a limited dining experience.", creditCost: 2_500, validDays: 30, requiredTier: .consul, status: .sealed, isRevealed: false, claimedAt: Date())
        ]
        return pool.randomElement() ?? pool[0]
    }
}

enum EventType: String, Codable, CaseIterable, Identifiable {
    case concert = "Concert"
    case game = "Game"
    case dining = "Dining"
    case party = "Party"
    case tournament = "Tournament"
    case special = "Special"

    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .concert: "music.mic"
        case .game: "suit.spade.fill"
        case .dining: "fork.knife"
        case .party: "sparkles"
        case .tournament: "trophy.fill"
        case .special: "star.fill"
        }
    }
}

enum EventAvailability: String, Codable {
    case open = "Open"
    case registrationOpen = "Registration Open"
    case inviteOnly = "Invite Only"
    case waitlist = "Waitlist"
    case spotsLeft = "5 Spots Left"
    case preregistration = "Pre-Registration"
    case earlyBird = "Early Bird Pricing"

    var color: Color {
        switch self {
        case .open, .registrationOpen, .spotsLeft: .successGreen
        case .waitlist, .preregistration, .earlyBird: .warningAmber
        case .inviteOnly: .caesarsRed
        }
    }
}

struct LoyaltyEvent: Identifiable, Hashable {
    let id: String
    let name: String
    let type: EventType
    let date: Date
    let displayDate: String
    let location: String
    let cost: String
    let details: String
    let availability: EventAvailability
    let requiredTier: LoyaltyStatus

    var assetName: String {
        switch id {
        case "adele-roman-nights": "event_9"
        case "summer-poker-classic": "event_5"
        case "bacchanal-emperors-feast": "event_6"
        case "ides-of-spins": "event_7"
        case "cirque-imperium": "event_3"
        case "member-appreciation-weekend": "event_8"
        case "blackjack-championship": "event_2"
        case "masks-of-rome": "event_4"
        case "wine-wisdom": "event_1"
        case "triumph-2027": "event_8"
        default: "event_0"
        }
    }

    var overlayAssetName: String {
        isVIP ? "event_overlay_vip" : "event_overlay"
    }

    var isVIP: Bool {
        requiredTier.rank >= LoyaltyStatus.consul.rank
        || availability == .inviteOnly
        || cost.localizedCaseInsensitiveContains("VIP")
    }

    static let seed: [LoyaltyEvent] = [
        LoyaltyEvent(id: "adele-roman-nights", name: "Adele: Roman Nights Residency", type: .concert, date: Date.caesars(2026, 6, 12, 20), displayDate: "Jun 12-13, 2026 at 8:00 PM", location: "The Colosseum", cost: "$150-$750", details: "A two-night residency featuring greatest hits with a Caesars orchestral arrangement. VIP includes backstage meet and greet.", availability: .open, requiredTier: .citizen),
        LoyaltyEvent(id: "summer-poker-classic", name: "Caesars Summer Poker Classic", type: .game, date: Date.caesars(2026, 7, 16, 12), displayDate: "Jul 16-19, 2026 at 12:00 PM daily", location: "Caesars Poker Room", cost: "$1,500 buy-in + 2,000 credits", details: "$500,000 guaranteed prize pool. Winner receives a WSOP Main Event seat and one-year status upgrade.", availability: .registrationOpen, requiredTier: .senator),
        LoyaltyEvent(id: "bacchanal-emperors-feast", name: "Bacchanal Buffet: Emperor's Feast", type: .dining, date: Date.caesars(2026, 8, 8, 19), displayDate: "Aug 8, 2026 at 7:00 PM", location: "Bacchanal Buffet", cost: "$300 per person + 1,500 credits", details: "Seven-course tasting menu with rare wine pairings. Limited to 24 guests.", availability: .inviteOnly, requiredTier: .emperor),
        LoyaltyEvent(id: "ides-of-spins", name: "Fall Slots Spectacular: Ides of Spins", type: .tournament, date: Date.caesars(2026, 9, 19, 18), displayDate: "Sep 19, 2026 at 6:00 PM", location: "Casino Floor", cost: "$75 entry + 300 credits", details: "$25,000 prize pool and hourly Golden Laurel bonuses for top performers.", availability: .waitlist, requiredTier: .citizen),
        LoyaltyEvent(id: "cirque-imperium", name: "Cirque du Soleil: IMPERIUM", type: .concert, date: Date.caesars(2026, 10, 7, 19), displayDate: "Oct 7-11, 2026 at 7:00 PM and 9:30 PM", location: "The Colosseum", cost: "$99-$399", details: "World premiere inspired by Ancient Rome with acrobatics, live music and VIP champagne reception.", availability: .open, requiredTier: .citizen),
        LoyaltyEvent(id: "member-appreciation-weekend", name: "Unity Member Appreciation Weekend", type: .special, date: Date.caesars(2026, 11, 7, 10), displayDate: "Nov 7-8, 2026 all day", location: "Caesars Palace", cost: "Free", details: "Double tier credits, hourly prize draws and member-only pop-up merchandise.", availability: .open, requiredTier: .citizen),
        LoyaltyEvent(id: "blackjack-championship", name: "High Limit Blackjack Championship", type: .tournament, date: Date.caesars(2026, 8, 23, 14), displayDate: "Aug 23, 2026 at 2:00 PM", location: "High Limit Salon", cost: "$2,000 buy-in + 3,000 credits", details: "$100,000 prize pool and exclusive Seven Stars pin for the winner.", availability: .spotsLeft, requiredTier: .consul),
        LoyaltyEvent(id: "masks-of-rome", name: "Halloween Masquerade: Masks of Rome", type: .party, date: Date.caesars(2026, 10, 31, 21), displayDate: "Oct 31, 2026 at 9:00 PM", location: "Omnia Nightclub", cost: "$60 entry + 500 credits", details: "Elegant masquerade with Roman flair, costume contest, live DJ and midnight toast.", availability: .preregistration, requiredTier: .citizen),
        LoyaltyEvent(id: "wine-wisdom", name: "Wine and Wisdom Masterclass", type: .dining, date: Date.caesars(2026, 9, 3, 18), displayDate: "Sep 3, 2026 at 6:00 PM", location: "Restaurant Guy Savoy", cost: "$150 + 800 credits", details: "Private masterclass with rare Italian vintages, appetizers and tasting journal.", availability: .open, requiredTier: .senator),
        LoyaltyEvent(id: "triumph-2027", name: "New Year's Eve: Triumph of 2027", type: .party, date: Date.caesars(2026, 12, 31, 21), displayDate: "Dec 31, 2026 at 9:00 PM", location: "Caesars Palace", cost: "$200 general / $500 VIP + 1,000 credits", details: "Live headliner, open bar for VIP, midnight buffet, champagne toast and commemorative coin.", availability: .earlyBird, requiredTier: .citizen)
    ].sorted { $0.date < $1.date }
}

struct CasinoGuide: Identifiable, Hashable {
    let id = UUID()
    let name: String
    let category: String
    let summary: String
    let difficulty: GameDifficulty
    let rules: [String]
    let strategy: [String]

    var assetName: String {
        "game_\(name)"
    }

    static let seed: [CasinoGuide] = [
        CasinoGuide(name: "Blackjack", category: "Table", summary: "Beat the dealer by reaching 21 or getting closer without busting.", difficulty: .easy, rules: ["Cards 2-10 count at face value.", "Face cards count as 10.", "Aces count as 1 or 11."], strategy: ["Learn a basic strategy chart.", "Avoid insurance bets.", "Stand on strong dealer-busting totals."]),
        CasinoGuide(name: "Roulette (European)", category: "Table", summary: "Bet on a number, color or section of the wheel.", difficulty: .easy, rules: ["European roulette has one zero.", "Inside bets pay more and hit less often.", "Outside bets are simpler and steadier."], strategy: ["Know the payout before placing a bet.", "Use smaller units for inside numbers.", "Set a session limit."]),
        CasinoGuide(name: "Texas Hold'em Poker", category: "Cards", summary: "Make the best five-card hand from two hole cards and five community cards.", difficulty: .medium, rules: ["Betting rounds are pre-flop, flop, turn and river.", "Best five-card poker hand wins.", "Position changes every hand."], strategy: ["Play tighter from early position.", "Observe opponent ranges.", "Protect strong hands on draw-heavy boards."]),
        CasinoGuide(name: "Baccarat", category: "Table", summary: "Bet on Player, Banker or Tie in a simple comparison game.", difficulty: .easy, rules: ["Closest hand to 9 wins.", "Third-card drawing is automatic.", "Banker bets usually pay commission."], strategy: ["Prefer Banker or Player over Tie.", "Avoid pattern chasing.", "Keep bet sizes consistent."]),
        CasinoGuide(name: "Craps", category: "Table", summary: "Bet on outcomes from rolling two dice.", difficulty: .hard, rules: ["Come-out roll sets the point.", "Pass Line wins on 7 or 11 before a point.", "Many proposition bets have higher house edge."], strategy: ["Start with Pass Line and odds.", "Add bets slowly.", "Avoid one-roll proposition bets."]),
        CasinoGuide(name: "Three Card Poker", category: "Cards", summary: "Build the best three-card hand against the dealer.", difficulty: .medium, rules: ["Ante starts the hand.", "Dealer must qualify.", "Pair Plus is a separate wager."], strategy: ["Play queen-six-four or better.", "Treat side bets as entertainment.", "Know table minimums."]),
        CasinoGuide(name: "Pai Gow Poker", category: "Cards", summary: "Split seven cards into five-card and two-card hands.", difficulty: .hard, rules: ["Both hands must beat dealer to win.", "Five-card hand must outrank two-card hand.", "Many outcomes push."], strategy: ["Use house-way guidance at first.", "Protect the high hand.", "Expect slower, lower-volatility play."]),
        CasinoGuide(name: "Let It Ride", category: "Cards", summary: "Make a poker hand from three private and two community cards.", difficulty: .medium, rules: ["Two optional withdrawals are offered.", "Final hand determines payout.", "Bonus pays by pay table."], strategy: ["Pull back weak starting hands.", "Keep three to a royal or straight flush.", "Read the pay table."]),
        CasinoGuide(name: "Caribbean Stud Poker", category: "Cards", summary: "Play poker against the dealer with a progressive option.", difficulty: .medium, rules: ["Dealer needs ace-king to qualify.", "Raise or fold after seeing one dealer card.", "Progressive wager is optional."], strategy: ["Raise ace-king-jack-eight-three or better.", "Avoid overvaluing the side bet.", "Compare pay tables."]),
        CasinoGuide(name: "Spanish 21", category: "Table", summary: "Blackjack variant with no tens and bonus payouts.", difficulty: .medium, rules: ["Tens are removed, face cards remain.", "Player 21 usually wins.", "Late surrender and double rules vary."], strategy: ["Use Spanish 21-specific strategy.", "Check local rule variations.", "Bonus hands change some decisions."]),
        CasinoGuide(name: "Video Poker (Jacks or Better)", category: "Video Poker", summary: "Draw to a pair of jacks or better.", difficulty: .medium, rules: ["Hold or discard after initial five cards.", "Final hand pays by table.", "Full-pay machines are valuable."], strategy: ["Learn hand priority.", "Check for 9/6 pay tables.", "Max coin often unlocks royal bonus."]),
        CasinoGuide(name: "Double Bonus Poker", category: "Video Poker", summary: "Bigger payouts for four-of-a-kind hands.", difficulty: .medium, rules: ["Based on draw poker.", "Four aces and kickers pay premium.", "Two pair payout may be lower."], strategy: ["Use the correct pay table strategy.", "Expect higher variance.", "Protect premium four-card draws."]),
        CasinoGuide(name: "Deuces Wild", category: "Video Poker", summary: "Twos are wild cards with higher volatility.", difficulty: .medium, rules: ["Every 2 substitutes for any card.", "Natural royal is top award.", "Pay tables differ sharply."], strategy: ["Never discard a deuce.", "Prioritize made wild royals.", "Use a game-specific chart."]),
        CasinoGuide(name: "Buffalo Slot", category: "Slots", summary: "Slot series with free games, multipliers and stacked symbols.", difficulty: .easy, rules: ["Wins pay left to right.", "Bonus triggers on scatter symbols.", "Free games can retrigger."], strategy: ["Choose a comfortable denomination.", "Know bonus volatility.", "Use time and loss limits."]),
        CasinoGuide(name: "Wheel of Fortune Slots", category: "Slots", summary: "Classic bonus-wheel slot series.", difficulty: .easy, rules: ["Spin reels for line pays.", "Wheel bonus awards credits.", "Progressive variants differ."], strategy: ["Check bet needed for jackpot eligibility.", "Treat wheel hits as volatile.", "Avoid chasing previous near-misses."]),
        CasinoGuide(name: "88 Fortunes", category: "Slots", summary: "Asian-themed slot with four jackpot levels.", difficulty: .easy, rules: ["Coin symbols can trigger a jackpot feature.", "Denomination changes jackpot values.", "Free games may appear by version."], strategy: ["Review jackpot eligibility.", "Pick a sustainable bet.", "Expect long dry spells."]),
        CasinoGuide(name: "Cleopatra Slots", category: "Slots", summary: "Egyptian-themed slots with free spins and multipliers.", difficulty: .easy, rules: ["Scatter symbols trigger free spins.", "Wilds substitute for many symbols.", "Multipliers apply in bonus rounds."], strategy: ["Read the version pay table.", "Keep bets consistent.", "Do not assume bonuses are due."]),
        CasinoGuide(name: "Lightning Link", category: "Slots", summary: "Progressive slot series with Hold and Spin bonuses.", difficulty: .easy, rules: ["Lightning balls can trigger bonus.", "Jackpot labels show credit values.", "Feature rules vary by cabinet."], strategy: ["Understand bet-to-jackpot scaling.", "Watch denomination before playing.", "Budget for high variance."]),
        CasinoGuide(name: "Dragon Link", category: "Slots", summary: "Slot series with linked jackpots and Hold and Spin feature.", difficulty: .easy, rules: ["Collect enough orb symbols for feature.", "Grand and Major are linked jackpots.", "Bonus resets spins after new orbs."], strategy: ["Confirm eligible bet levels.", "Avoid increasing bets to chase features.", "Use session reminders."]),
        CasinoGuide(name: "Ultimate Texas Hold'em", category: "Table", summary: "Poker against the dealer with timed raise decisions.", difficulty: .hard, rules: ["Raise 4x pre-flop, 2x on flop or 1x on river.", "Dealer must qualify for ante.", "Trips is a side bet."], strategy: ["Use a raise strategy by hand strength.", "Do not limp strong openers.", "Manage side bet exposure."])
    ]
}

enum GameDifficulty: String, Codable, CaseIterable, Identifiable {
    case easy = "Easy"
    case medium = "Medium"
    case hard = "Hard"

    var id: String { rawValue }
    var color: Color {
        switch self {
        case .easy: .successGreen
        case .medium: .warningAmber
        case .hard: .caesarsRed
        }
    }
}

struct LoyaltyChallenge: Identifiable, Codable, Hashable {
    var id = UUID()
    var title: String
    var requirement: String
    var reward: String
    var current: Int
    var target: Int
    var step: Int
    var creditReward: Int
    var symbol: String
    var isClaimed: Bool

    var progress: Double {
        min(1, Double(current) / Double(max(1, target)))
    }

    var assetName: String {
        switch title {
        case "Blackjack Conqueror": "chalenge_0"
        case "Slot Emperor": "chalenge_1"
        case "Gastronome": "chalenge_2"
        case "Arts Patron": "chalenge_3"
        case "Imperial Status": "chalenge_4"
        default: "chalenge_0"
        }
    }

    static let seed: [LoyaltyChallenge] = [
        LoyaltyChallenge(title: "Blackjack Conqueror", requirement: "Log 10 blackjack hands this week.", reward: "200 credits", current: 3, target: 10, step: 1, creditReward: 200, symbol: "suit.club.fill", isClaimed: false),
        LoyaltyChallenge(title: "Slot Emperor", requirement: "Log 50 spins on any slot.", reward: "150 credits and 10 free spins", current: 18, target: 50, step: 5, creditReward: 150, symbol: "circle.grid.cross.fill", isClaimed: false),
        LoyaltyChallenge(title: "Gastronome", requirement: "Record one Caesars dining visit.", reward: "10% cashback in credits", current: 0, target: 1, step: 1, creditReward: 100, symbol: "fork.knife", isClaimed: false),
        LoyaltyChallenge(title: "Arts Patron", requirement: "Register for a Colosseum show.", reward: "Exclusive merchandise access", current: 0, target: 1, step: 1, creditReward: 100, symbol: "theatermasks.fill", isClaimed: false),
        LoyaltyChallenge(title: "Imperial Status", requirement: "Reach Diamond-level progress this month.", reward: "Chef's dinner invitation", current: 1_500, target: 6_000, step: 250, creditReward: 500, symbol: "crown.fill", isClaimed: false)
    ]
}

struct NotificationSettings: Codable {
    var rewards = true
    var events = true
    var offers = false
}

struct AppSnapshot: Codable {
    var session: SessionState
    var rewards: [RewardScroll]
    var registeredEventIDs: Set<String>
    var challenges: [LoyaltyChallenge]
    var notificationSettings: NotificationSettings
}

struct LocalStorage {
    private let key = "caesars.unity.loyal.snapshot"

    func load() -> AppSnapshot {
        guard let data = UserDefaults.standard.data(forKey: key) else {
            return AppSnapshot(session: SessionState(), rewards: [], registeredEventIDs: [], challenges: [], notificationSettings: NotificationSettings())
        }
        do {
            return try JSONDecoder().decode(AppSnapshot.self, from: data)
        } catch {
            return AppSnapshot(session: SessionState(), rewards: [], registeredEventIDs: [], challenges: [], notificationSettings: NotificationSettings())
        }
    }

    func save(_ snapshot: AppSnapshot) {
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        UserDefaults.standard.set(data, forKey: key)
        UserDefaults.standard.synchronize()
    }
}

enum AppError: LocalizedError {
    case validation(String)

    var errorDescription: String? {
        switch self {
        case .validation(let message): message
        }
    }
}

struct AuthenticationView: View {
    @EnvironmentObject private var store: LoyaltyStore
    @State private var email = ""
    @State private var password = ""
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var logoAppeared = false
    @FocusState private var focusedField: Field?

    private enum Field {
        case email
        case password
    }

    var body: some View {
        NavigationStack {
            ZStack {
                LoginBackgroundView()

                VStack(spacing: 22) {
                    Spacer(minLength: 24)

                    AssetImage("LoginLogo", contentMode: .fit) {
                    }
                    .frame(width: 256, height: 126)
                    .shadow(color: .black.opacity(0.22), radius: 18, y: 10)
                    .scaleEffect(logoAppeared ? 1 : 0.82)
                    .opacity(logoAppeared ? 1 : 0)
                    .animation(.spring(response: 0.55, dampingFraction: 0.74), value: logoAppeared)
                    .accessibilityLabel("Caesars Palace Unity Loyal logo")

                    VStack(spacing: 14) {
                        TextField("Email", text: $email)
                            .textContentType(.emailAddress)
                            .textInputAutocapitalization(.never)
                            .keyboardType(.emailAddress)
                            .autocorrectionDisabled()
                            .focused($focusedField, equals: .email)
                            .submitLabel(.next)
                            .onSubmit { focusedField = .password }
                            .accessibilityLabel("Email")

                        SecureField("Password", text: $password)
                            .textContentType(.password)
                            .focused($focusedField, equals: .password)
                            .submitLabel(.go)
                            .onSubmit { signIn() }
                            .accessibilityLabel("Password")

                        if let errorMessage {
                            Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                                .font(.footnote)
                                .foregroundStyle(Color.caesarsRed)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }

                        Button(action: signIn) {
                            if isLoading {
                                ProgressView()
                                    .controlSize(.small)
                                    .frame(maxWidth: .infinity, minHeight: 20)
                            } else {
                                Text("Sign In")
                                    .frame(maxWidth: .infinity)
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .disabled(isLoading)
                        .accessibilityLabel("Sign in")
                    }
                    .textFieldStyle(.roundedBorder)
                    .padding(18)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                    .frame(maxWidth: 420)

                    Spacer(minLength: 24)
                }
                .padding(.horizontal, 24)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .scrollDismissesKeyboard(.interactively)
                .onTapGesture { focusedField = nil }
                .onAppear {
                    logoAppeared = true
                }
            }
        }
    }

    private func signIn() {
        focusedField = nil
        isLoading = true
        errorMessage = nil
        Task {
            do {
                try await store.signIn(email: email, password: password)
            } catch {
                errorMessage = error.localizedDescription
            }
            isLoading = false
        }
    }
}

struct ProfileHubView: View {
    @EnvironmentObject private var store: LoyaltyStore
    @Binding var selectedTab: AppTab

    var body: some View {
        List {
            Section {
                ProfileHeader(profile: store.session.profile) { data in
                    store.updateAvatarImageData(data)
                }
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
            }

            Section("Quick Actions") {
                Button {
                    selectedTab = .scrolls
                } label: {
                    Label("Reward Scrolls", systemImage: "scroll")
                }
                Button {
                    selectedTab = .events
                } label: {
                    Label("Empire Calendar", systemImage: "calendar")
                }
                Button {
                    selectedTab = .games
                } label: {
                    Label("Game Library", systemImage: "books.vertical")
                }
            }

            Section("Progress") {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text(store.session.profile.nextStatus?.title ?? "Top Status")
                            .font(.headline)
                        Spacer()
                        Text("\(Int(store.session.profile.progressToNextStatus * 100))%")
                            .font(.subheadline.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    ProgressView(value: store.session.profile.progressToNextStatus)
                        .tint(Color.gold)
                    if let next = store.session.profile.nextStatus {
                        Text("\((next.minimumCredits - store.session.profile.tierCredits).formatted()) credits to \(next.title).")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("You have reached the highest local loyalty tier.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 6)
            }

        }
        .navigationTitle("My Profile")
        .scrollContentBackground(.hidden)
        .background(AppSharedBackground())
    }
}

struct ProfileHeader: View {
    let profile: UserProfile
    let updateAvatar: (Data?) -> Void
    @State private var selectedPhoto: PhotosPickerItem?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .center, spacing: 16) {
                PhotosPicker(selection: $selectedPhoto, matching: .images) {
                    AvatarView(profile: profile)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Change profile avatar")
                .onChange(of: selectedPhoto) { _, item in
                    Task {
                        let data = try? await item?.loadTransferable(type: Data.self)
                        updateAvatar(data)
                    }
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text(profile.name)
                        .font(.title2.bold())
                    HStack(spacing: 6) {
                        LoyaltyStatusMark(status: profile.status, size: 24)
                        Text(profile.status.title)
                            .font(.subheadline.weight(.semibold))
                    }
                    .foregroundStyle(Color.gold)
                    Text(profile.email)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Tier Credits")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Text(profile.tierCredits.formatted())
                    .font(.system(.largeTitle, design: .monospaced, weight: .bold))
                    .contentTransition(.numericText())
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            LinearGradient(colors: profile.status.panelColors, startPoint: .topLeading, endPoint: .bottomTrailing),
            in: RoundedRectangle(cornerRadius: 22, style: .continuous)
        )
        .foregroundStyle(.white)
        .padding(.horizontal)
        .padding(.vertical, 8)
    }
}

struct AvatarView: View {
    let profile: UserProfile

    var body: some View {
        ZStack {
            AssetImage("UserAvatarLaurelWreath", contentMode: .fit) {
                Image(systemName: "laurel.leading")
                    .font(.system(size: 62, weight: .bold))
                    .foregroundStyle(Color.gold)
            }
            .frame(width: 96, height: 96)

            Group {
                if let data = profile.avatarImageData, let image = UIImage(data: data) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                } else {
                    Image(systemName: "person.crop.circle.fill")
                        .resizable()
                        .scaledToFit()
                        .foregroundStyle(.white.opacity(0.9), Color.gold.opacity(0.65))
                        .padding(10)
                }
            }
            .frame(width: 68, height: 68)
            .clipped()
            .background(.thinMaterial, in: Circle())
            .clipShape(Circle())
            .overlay(Circle().stroke(Color.gold, lineWidth: 2))

            Image(systemName: "camera.fill")
                .font(.caption)
                .foregroundStyle(.white)
                .padding(6)
                .background(Color.caesarsRed, in: Circle())
                .offset(x: 32, y: 32)
        }
        .frame(width: 96, height: 96)
    }
}

struct ScrollsView: View {
    @EnvironmentObject private var store: LoyaltyStore
    @State private var alert: AlertPayload?
    @State private var selectedReward: RewardScroll?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                Button {
                    do {
                        try store.claimDailyScroll()
                    } catch {
                        alert = AlertPayload(message: error.localizedDescription)
                    }
                } label: {
                    Label("Claim New Daily Scroll", systemImage: "plus.circle.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

                let activeRewards = store.rewards.filter { $0.status != .activated && $0.status != .expired }

                VStack(alignment: .leading, spacing: 14) {
                    if activeRewards.isEmpty {
                        EmptyStateView(title: "No sealed scrolls", message: "Claim a new scroll to place it on the table.", symbol: "scroll")
                    } else {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 16) {
                                ForEach(activeRewards) { reward in
                                    ClosedRewardScrollView(reward: reward)
                                        .onTapGesture {
                                            selectedReward = reward
                                            if !reward.isRevealed {
                                                store.revealReward(reward)
                                            }
                                        }
                                        .accessibilityAddTraits(.isButton)
                                }
                            }
                            .padding(.horizontal, 4)
                        }
                    }
                }
                .padding(16)
                .background {
                    AssetPanelBackground(assetName: "MarbleTableSurface", fallbackColors: [Color.white, Color.gold.opacity(0.22)])
                        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                }
                .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(Color.gold.opacity(0.35), lineWidth: 1))

                let activated = store.rewards.filter { $0.status == .activated }
                VStack(alignment: .leading, spacing: 14) {
                    Text("Activated Scrolls")
                        .font(.headline)
                    if activated.isEmpty {
                        EmptyStateView(title: "No activated scrolls", message: "Activated rewards will appear here with their expiration dates.", symbol: "checkmark.seal")
                    } else {
                        LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                            ForEach(activated) { reward in
                                ActivatedRewardScrollView(reward: reward)
                            }
                        }
                    }
                }
            }
            .padding()
            .frame(maxWidth: 760)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("Fortune Scrolls")
        .background(AppSharedBackground())
        .sheet(item: $selectedReward) { reward in
            RewardDetailPanel(reward: currentReward(for: reward)) {
                try store.activateReward(currentReward(for: reward))
                selectedReward = nil
            }
            .presentationDetents([.medium, .large])
        }
        .alert(item: $alert) { payload in
            Alert(title: Text("Action Needed"), message: Text(payload.message), dismissButton: .default(Text("OK")))
        }
    }

    private func currentReward(for reward: RewardScroll) -> RewardScroll {
        store.rewards.first { $0.id == reward.id } ?? reward
    }
}

struct ClosedRewardScrollView: View {
    let reward: RewardScroll

    var body: some View {
        AssetImage("scroll", contentMode: .fill) {
            Image(systemName: "scroll")
                .font(.largeTitle)
                .foregroundStyle(Color.gold)
        }
        .frame(width: 96, height: 156)
        .accessibilityLabel("\(reward.title), \(reward.status.title)")
    }
}

struct RewardDetailPanel: View {
    let reward: RewardScroll
    let activate: () throws -> Void
    @State private var alert: AlertPayload?

    var body: some View {
        ZStack {
            AssetImage("scroll_unwrapped", contentMode: .fill) {
                AssetPanelBackground(assetName: "OpenedRewardScroll", fallbackColors: [Color.scrollParchment, Color.white])
            }
            .ignoresSafeArea()

            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 10) {
                    Text(reward.title)
                        .font(.system(.title3, design: .serif, weight: .bold))
                        .foregroundStyle(Color.black.opacity(0.9))
                        .fixedSize(horizontal: false, vertical: true)

                    Text(reward.description)
                        .font(.callout)
                        .foregroundStyle(Color.black.opacity(0.82))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                RewardDetailRow(title: "Activation Cost", value: "\(reward.creditCost.formatted()) credits", symbol: "creditcard")
                RewardDetailRow(title: "Valid For", value: "\(reward.validDays) days", symbol: "calendar.badge.clock")
                if let requiredTier = reward.requiredTier {
                    RewardStatusDetailRow(title: "Required Status", status: requiredTier)
                }

                Button {
                    do {
                        try activate()
                    } catch {
                        alert = AlertPayload(message: error.localizedDescription)
                    }
                } label: {
                    Text(reward.status == .activated ? "Activated" : "Activate")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(reward.status == .activated)
            }
            .padding()
            .padding(.top, 20)
        }
        .alert(item: $alert) { payload in
            Alert(title: Text("Activation"), message: Text(payload.message), dismissButton: .default(Text("OK")))
        }
    }
}

struct ActivatedRewardScrollView: View {
    let reward: RewardScroll

    var body: some View {
        RewardScrollInfoCard(reward: reward, assetName: "scroll activated", showsExpiration: true)
            .frame(height: 240)
    }
}

struct RewardScrollInfoCard: View {
    let reward: RewardScroll
    let assetName: String
    let showsExpiration: Bool

    var body: some View {
        ZStack {
            AssetImage(assetName, contentMode: .fill) {
                AssetPanelBackground(assetName: "OpenedRewardScroll", fallbackColors: [Color.scrollParchment, Color.white])
            }

            VStack(spacing: 8) {
                Text(reward.title)
                    .font(.system(.headline, design: .serif, weight: .bold))
                    .foregroundStyle(Color.white)
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
                    .minimumScaleFactor(0.78)

                Text(reward.description)
                    .font(.caption)
                    .foregroundStyle(Color.white)
                    .multilineTextAlignment(.center)
                    .lineLimit(5)
                    .minimumScaleFactor(0.78)

                if showsExpiration {
                    Text("Expires \(reward.expirationDate.formatted(date: .abbreviated, time: .omitted))")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(Color.white)
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                        .minimumScaleFactor(0.78)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 18)
        }
        .clipped()
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(Color.gold.opacity(0.35), lineWidth: 1))
    }
}

struct RewardDetailRow: View {
    let title: String
    let value: String
    let symbol: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .foregroundStyle(Color.black.opacity(0.78))
                .frame(width: 24)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.black.opacity(0.7))
                Text(value)
                    .foregroundStyle(Color.black.opacity(0.88))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

struct RewardStatusDetailRow: View {
    let title: String
    let status: LoyaltyStatus

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            LoyaltyStatusMark(status: status, size: 24)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.black.opacity(0.7))
                Text(status.title)
                    .foregroundStyle(Color.black.opacity(0.88))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

struct EventsView: View {
    @EnvironmentObject private var store: LoyaltyStore
    @State private var selectedType: EventType?
    @State private var alert: AlertPayload?
    @State private var displayedMonth = Date.caesars(2026, 6, 1, 12)
    @State private var selectedEvent: LoyaltyEvent?

    var filteredEvents: [LoyaltyEvent] {
        guard let selectedType else { return store.events }
        return store.events.filter { $0.type == selectedType }
    }

    var body: some View {
        List {
            Section {
                Picker("Event Type", selection: $selectedType) {
                    Text("All").tag(nil as EventType?)
                    ForEach(EventType.allCases) { type in
                        Label(type.rawValue, systemImage: type.symbol).tag(type as EventType?)
                    }
                }
                .pickerStyle(.menu)
            }

            Section("Registered") {
                let registered = store.events.filter { store.registeredEventIDs.contains($0.id) }
                if registered.isEmpty {
                    EmptyStateView(title: "No registrations", message: "Register for an event to keep it in your Unity itinerary.", symbol: "ticket")
                } else {
                    ForEach(registered) { event in
                        EventRow(event: event, isRegistered: true)
                    }
                }
            }

            Section("Calendar") {
                MonthMarkerGrid(events: store.events, displayedMonth: $displayedMonth)
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
            }

            Section("Upcoming Events") {
                ForEach(filteredEvents) { event in
                    Button {
                        selectedEvent = event
                    } label: {
                        EventRow(event: event, isRegistered: store.registeredEventIDs.contains(event.id))
                    }
                    .buttonStyle(.plain)
                    .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                }
            }
        }
        .navigationTitle("Empire Calendar")
        .navigationDestination(item: $selectedEvent) { event in
            EventDetailView(event: event)
        }
        .scrollContentBackground(.hidden)
        .background(AppSharedBackground())
        .alert(item: $alert) { payload in
            Alert(title: Text("Registration"), message: Text(payload.message), dismissButton: .default(Text("OK")))
        }
    }
}

struct EventDetailView: View {
    @EnvironmentObject private var store: LoyaltyStore
    let event: LoyaltyEvent
    @State private var alert: AlertPayload?
    @State private var didRegister = false

    var isRegistered: Bool {
        store.registeredEventIDs.contains(event.id)
    }

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 16) {
                    EventArtwork(event: event)
                        .frame(height: 190)
                    StatusPill(title: event.availability.rawValue, color: event.availability.color)
                    Text(event.name)
                        .font(.title2.bold())
                        .fixedSize(horizontal: false, vertical: true)
                    Text(event.details)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.vertical, 6)
            }

            Section("Details") {
                DetailRow(title: "Date", value: event.displayDate, symbol: "calendar")
                DetailRow(title: "Location", value: event.location, symbol: "mappin.and.ellipse")
                DetailRow(title: "Entry", value: event.cost, symbol: "creditcard")
                StatusDetailRow(title: "Required Status", status: event.requiredTier)
            }

            Section {
                if isRegistered {
                    Button(role: .destructive) {
                        store.unregister(from: event)
                    } label: {
                        Label("Cancel Registration", systemImage: "xmark.circle")
                    }
                } else {
                    Button {
                        do {
                            try store.register(for: event)
                            didRegister = true
                        } catch {
                            alert = AlertPayload(message: error.localizedDescription)
                        }
                    } label: {
                        Text("Register")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(AppSharedBackground())
        .navigationTitle("Event")
        .navigationBarTitleDisplayMode(.inline)
        .alert(item: $alert) { payload in
            Alert(title: Text("Registration Unavailable"), message: Text(payload.message), dismissButton: .default(Text("OK")))
        }
        .alert("Registered", isPresented: $didRegister) {
            Button("OK", role: .cancel) { }
        } message: {
            Text("This event was added to your in-app Unity itinerary.")
        }
    }
}

struct GameLibraryView: View {
    @EnvironmentObject private var store: LoyaltyStore
    @State private var selectedCategory = "All"
    @State private var searchText = ""
    @State private var selectedGame: CasinoGuide?

    var categories: [String] {
        ["All"] + Array(Set(store.games.map(\.category))).sorted()
    }

    var filteredGames: [CasinoGuide] {
        store.games.filter { game in
            (selectedCategory == "All" || game.category == selectedCategory)
            && (searchText.isEmpty || game.name.localizedCaseInsensitiveContains(searchText) || game.summary.localizedCaseInsensitiveContains(searchText))
        }
    }

    var body: some View {
        List {
            Section {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(categories, id: \.self) { category in
                            Button {
                                selectedCategory = category
                            } label: {
                                Text(category)
                                    .font(.subheadline.weight(.semibold))
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 8)
                                    .foregroundStyle(selectedCategory == category ? Color.white : Color.primary)
                                    .background(selectedCategory == category ? Color.caesarsRed : Color(uiColor: .secondarySystemGroupedBackground), in: Capsule())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }

            if filteredGames.isEmpty {
                EmptyStateView(title: "No games found", message: "Try another category or search term.", symbol: "magnifyingglass")
            } else {
                Section("Guides") {
                    ForEach(filteredGames) { game in
                        Button {
                            selectedGame = game
                        } label: {
                            GameRow(game: game)
                        }
                        .buttonStyle(.plain)
                        .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                    }
                }
            }
        }
        .navigationTitle("Game Library")
        .navigationDestination(item: $selectedGame) { game in
            GameDetailView(game: game)
        }
        .searchable(text: $searchText, prompt: "Search games")
        .scrollContentBackground(.hidden)
        .background(AppSharedBackground())
    }
}

struct GameDetailView: View {
    let game: CasinoGuide

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 12) {
                    AssetImage(game.assetName, contentMode: .fit) {
                        Image(systemName: "suit.spade.fill")
                            .font(.system(size: 56, weight: .semibold))
                            .foregroundStyle(Color.gold)
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 120)
                    .accessibilityHidden(true)

                    Text(game.name)
                        .font(.title2.bold())
                        .fixedSize(horizontal: false, vertical: true)
                    HStack {
                        StatusPill(title: game.category, color: Color.gold)
                        StatusPill(title: game.difficulty.rawValue, color: game.difficulty.color)
                    }
                    Text(game.summary)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Section("Rules") {
                ForEach(game.rules, id: \.self) { rule in
                    Label(rule, systemImage: "checkmark.circle")
                }
            }

            Section("Strategy Notes") {
                ForEach(game.strategy, id: \.self) { note in
                    Label(note, systemImage: "lightbulb")
                }
            }

            Section {
                Label("Educational guide only. No wagering or real-money play is available in this app.", systemImage: "info.circle")
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle(game.name)
        .navigationBarTitleDisplayMode(.inline)
        .scrollContentBackground(.hidden)
        .background(AppSharedBackground())
    }
}

struct ChallengesView: View {
    @EnvironmentObject private var store: LoyaltyStore
    @State private var alert: AlertPayload?

    var body: some View {
        List {
            Section {
                Text("Monthly goals turn Unity activity into clear progress. Completed rewards can be claimed locally.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Section("Colosseum Challenges") {
                ForEach(store.challenges) { challenge in
                    ChallengeCard(challenge: challenge) {
                        do {
                            try store.claimChallenge(challenge)
                        } catch {
                            alert = AlertPayload(message: error.localizedDescription)
                        }
                    }
                    .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                }
            }
        }
        .navigationTitle("Challenges")
        .scrollContentBackground(.hidden)
        .background(AppSharedBackground())
        .alert(item: $alert) { payload in
            Alert(title: Text("Challenge"), message: Text(payload.message), dismissButton: .default(Text("OK")))
        }
    }
}

struct ChallengeCard: View {
    let challenge: LoyaltyChallenge
    let claim: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                AssetImage(challenge.assetName, contentMode: .fit) {
                    Image(systemName: challenge.symbol)
                        .font(.system(size: 44, weight: .semibold))
                        .foregroundStyle(Color.gold)
                }
                .frame(width: 86, height: 86)
                .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(challenge.title)
                        .font(.headline)
                    Text(challenge.requirement)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }

            ProgressView(value: challenge.progress)
                .tint(challenge.isClaimed ? Color.successGreen : Color.gold)
            HStack {
                Text("\(challenge.current.formatted()) / \(challenge.target.formatted())")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Spacer()
                Text(challenge.reward)
                    .font(.caption.weight(.semibold))
            }

            Button(challenge.isClaimed ? "Claimed" : "Claim Reward") {
                claim()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .frame(maxWidth: .infinity, alignment: .trailing)
            .disabled(challenge.isClaimed)
        }
        .padding(16)
        .background {
            AssetPanelBackground(assetName: "ChallengeCardBackground", fallbackColors: [Color.white, Color.caesarsRed.opacity(0.08)])
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color(uiColor: .separator).opacity(0.4), lineWidth: 1)
        )
    }
}

struct SettingsView: View {
    @EnvironmentObject private var store: LoyaltyStore
    @State private var displayName = ""
    @State private var currentPassword = ""
    @State private var newPassword = ""
    @State private var confirmation = ""
    @State private var notifications = NotificationSettings()
    @State private var alert: AlertPayload?
    @State private var showDeleteConfirmation = false
    @FocusState private var focusedField: Field?

    private enum Field {
        case name
        case current
        case newPassword
        case confirmation
    }

    var body: some View {
        Form {
            Section("Profile") {
                TextField("Display Name", text: $displayName)
                    .focused($focusedField, equals: .name)
                    .submitLabel(.done)
                Button("Save Name") {
                    do {
                        try store.changeDisplayName(displayName)
                        alert = AlertPayload(message: "Your display name was updated.")
                    } catch {
                        alert = AlertPayload(message: error.localizedDescription)
                    }
                    focusedField = nil
                }
            }

            Section("Password") {
                SecureField("Current Password", text: $currentPassword)
                    .focused($focusedField, equals: .current)
                SecureField("New Password", text: $newPassword)
                    .focused($focusedField, equals: .newPassword)
                SecureField("Confirm New Password", text: $confirmation)
                    .focused($focusedField, equals: .confirmation)
                Button("Change Password") {
                    do {
                        try store.changePassword(current: currentPassword, newPassword: newPassword, confirmation: confirmation)
                        currentPassword = ""
                        newPassword = ""
                        confirmation = ""
                        alert = AlertPayload(message: "Password was changed for the local account.")
                    } catch {
                        alert = AlertPayload(message: error.localizedDescription)
                    }
                    focusedField = nil
                }
            }

            Section("Notifications") {
                Toggle("Rewards", isOn: $notifications.rewards)
                Toggle("Events", isOn: $notifications.events)
                Toggle("Personal Offers", isOn: $notifications.offers)
                Button("Save Notification Settings") {
                    store.saveNotifications(notifications)
                    alert = AlertPayload(message: "Notification preferences were saved locally.")
                }
            }

            Section("Account") {
                Button("Sign Out") {
                    store.signOut()
                }
                Button("Delete Local Account", role: .destructive) {
                    showDeleteConfirmation = true
                }
            }
        }
        .navigationTitle("Settings")
        .scrollContentBackground(.hidden)
        .background(AppSharedBackground())
        .scrollDismissesKeyboard(.interactively)
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") { focusedField = nil }
            }
        }
        .onAppear {
            displayName = store.session.profile.name
            notifications = store.notificationSettings
        }
        .alert(item: $alert) { payload in
            Alert(title: Text("Settings"), message: Text(payload.message), dismissButton: .default(Text("OK")))
        }
        .confirmationDialog("Delete the local account and saved loyalty data?", isPresented: $showDeleteConfirmation, titleVisibility: .visible) {
            Button("Delete Account", role: .destructive) {
                store.deleteAccount()
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This removes locally saved profile, scroll, event and challenge data from this device.")
        }
    }
}

struct EventRow: View {
    let event: LoyaltyEvent
    let isRegistered: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            EventArtwork(event: event)
                .frame(height: 128)

            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(event.name)
                        .font(.headline)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(event.displayDate)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    HStack {
                        StatusPill(title: event.availability.rawValue, color: event.availability.color)
                        if isRegistered {
                            StatusPill(title: "Registered", color: Color.successGreen)
                        }
                    }
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            AssetPanelBackground(assetName: "EventCardBackground", fallbackColors: [Color.white, Color.gold.opacity(0.14)])
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Color.gold.opacity(0.25), lineWidth: 1))
    }
}

struct GameRow: View {
    let game: CasinoGuide

    var body: some View {
        HStack(spacing: 12) {
            AssetImage(game.assetName, contentMode: .fit) {
                Image(systemName: "suit.spade.fill")
                    .font(.title2)
                    .foregroundStyle(Color.gold)
            }
            .frame(width: 54, height: 54)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                Text(game.name)
                    .font(.headline)
                    .fixedSize(horizontal: false, vertical: true)
                Text(game.summary)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                HStack {
                    StatusPill(title: game.category, color: Color.gold)
                    StatusPill(title: game.difficulty.rawValue, color: game.difficulty.color)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            AssetPanelBackground(assetName: "GameCardBackground", fallbackColors: [Color.white, Color.gold.opacity(0.12)])
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Color.gold.opacity(0.25), lineWidth: 1))
    }
}

struct MonthMarkerGrid: View {
    let events: [LoyaltyEvent]
    @Binding var displayedMonth: Date
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 8), count: 7)

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Button {
                    displayedMonth = Calendar.current.date(byAdding: .month, value: -1, to: displayedMonth) ?? displayedMonth
                } label: {
                    Image(systemName: "chevron.left")
                        .frame(width: 36, height: 36)
                }
                .buttonStyle(.bordered)

                Spacer()
                Text(displayedMonth.formatted(.dateTime.month(.wide).year()))
                    .font(.headline)
                Spacer()

                Button {
                    displayedMonth = Calendar.current.date(byAdding: .month, value: 1, to: displayedMonth) ?? displayedMonth
                } label: {
                    Image(systemName: "chevron.right")
                        .frame(width: 36, height: 36)
                }
                .buttonStyle(.bordered)
            }
            .padding(.horizontal)

            LazyVGrid(columns: columns, spacing: 8) {
                ForEach(daysInDisplayedMonth, id: \.self) { day in
                    let hasEvent = events.contains { event in
                        Calendar.current.isDate(event.date, equalTo: displayedMonth, toGranularity: .month)
                        && Calendar.current.component(.day, from: event.date) == day
                    }
                    ZStack {
                        AssetPanelBackground(assetName: "CalendarDayTile", fallbackColors: [Color.white, Color.gold.opacity(0.12)])
                        Text("\(day)")
                            .font(.caption.monospacedDigit())
                            .fontWeight(hasEvent ? .bold : .regular)
                            .foregroundStyle(hasEvent ? Color.gold : Color.black)
                    }
                    .frame(height: 42)
                    .frame(maxWidth: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .accessibilityLabel(hasEvent ? "Day \(day), event available" : "Day \(day), no event")
                }
            }
            .padding(.horizontal)
        }
        .padding(.vertical)
        .background {
            AssetPanelBackground(assetName: "CalendarBoardBackground", fallbackColors: [Color.white, Color.caesarsRed.opacity(0.09)])
                .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        }
    }

    private var daysInDisplayedMonth: [Int] {
        let range = Calendar.current.range(of: .day, in: .month, for: displayedMonth) ?? 1..<31
        return Array(range)
    }
}

struct LoyaltyStatusMark: View {
    let status: LoyaltyStatus
    let size: CGFloat

    var body: some View {
        AssetImage(status.assetName, contentMode: .fit) {
            Image(systemName: status.symbol)
                .font(.system(size: size * 0.55, weight: .semibold))
                .foregroundStyle(Color.gold)
        }
        .frame(width: size, height: size)
        .accessibilityLabel(status.title)
    }
}

struct EventArtwork: View {
    let event: LoyaltyEvent

    var body: some View {
        ZStack {
            AssetImage(event.assetName, contentMode: .fill) {
                LinearGradient(colors: [Color.caesarsRed.opacity(0.74), Color.gold.opacity(0.42)], startPoint: .topLeading, endPoint: .bottomTrailing)
            }

            AssetImage(event.overlayAssetName, contentMode: .fill) {
                Color.black.opacity(0.18)
            }
        }
        .clipped()
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .accessibilityHidden(true)
    }
}

struct AssetArtwork: View {
    let assetName: String
    let symbol: String

    var body: some View {
        ZStack {
            AssetImage(assetName, contentMode: .fill) {
                LinearGradient(colors: [Color.caesarsRed.opacity(0.78), Color.gold.opacity(0.52)], startPoint: .topLeading, endPoint: .bottomTrailing)
            }
            if UIImage(named: assetName) == nil {
                Image(systemName: symbol)
                    .font(.system(size: 34, weight: .semibold))
                    .foregroundStyle(.white)
            }
        }
        .clipped()
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .accessibilityHidden(true)
    }
}

struct LoginBackgroundView: View {
    var body: some View {
        ZStack {
            AssetImage("LoginBackground", contentMode: .fill) {
                LinearGradient(colors: [Color.white, Color.gold.opacity(0.22), Color.caesarsRed.opacity(0.18)], startPoint: .topLeading, endPoint: .bottomTrailing)
            }
            .ignoresSafeArea()
            Color.black.opacity(0.08).ignoresSafeArea()
        }
    }
}

struct AppSharedBackground: View {
    var body: some View {
        ZStack {
            AssetImage("AppSharedBackground", contentMode: .fill) {
                LinearGradient(colors: [Color.marble, Color.white, Color.gold.opacity(0.10)], startPoint: .topLeading, endPoint: .bottomTrailing)
            }
            .ignoresSafeArea()
            Color.white.opacity(0.14).ignoresSafeArea()
        }
    }
}

struct AssetPanelBackground: View {
    let assetName: String
    let fallbackColors: [Color]

    var body: some View {
        AssetImage(assetName, contentMode: .fill) {
            LinearGradient(colors: fallbackColors, startPoint: .topLeading, endPoint: .bottomTrailing)
        }
        .clipped()
    }
}

struct AssetImage<Fallback: View>: View {
    let assetName: String
    let contentMode: ContentMode
    let fallback: Fallback

    init(_ assetName: String, contentMode: ContentMode, @ViewBuilder fallback: () -> Fallback) {
        self.assetName = assetName
        self.contentMode = contentMode
        self.fallback = fallback()
    }

    var body: some View {
        GeometryReader { proxy in
            Group {
                if let image = UIImage(named: assetName) {
                    Image(uiImage: image)
                        .resizable()
                        .aspectRatio(contentMode: contentMode)
                } else {
                    fallback
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .clipped()
        }
        .clipped()
    }
}

struct EmptyStateView: View {
    let title: String
    let message: String
    let symbol: String

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.title)
                .foregroundStyle(.secondary)
            Text(title)
                .font(.headline)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
        .accessibilityElement(children: .combine)
    }
}

struct StatusPill: View {
    let title: String
    let color: Color

    var body: some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .foregroundStyle(color)
            .background(color.opacity(0.14), in: Capsule())
    }
}

struct DetailRow: View {
    let title: String
    let value: String
    let symbol: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .foregroundStyle(Color.gold)
                .frame(width: 24)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(value)
            }
        }
    }
}

struct StatusDetailRow: View {
    let title: String
    let status: LoyaltyStatus

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            LoyaltyStatusMark(status: status, size: 24)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(status.title)
            }
        }
    }
}

struct StatRow: View {
    let title: String
    let value: String
    let symbol: String
    let color: Color

    var body: some View {
        HStack {
            Label(title, systemImage: symbol)
            Spacer()
            Text(value)
                .font(.headline.monospacedDigit())
                .foregroundStyle(color)
        }
    }
}

struct AlertPayload: Identifiable {
    let id = UUID()
    let message: String
}

extension Color {
    static let caesarsRed = Color(red: 0.545, green: 0, blue: 0)
    static let gold = Color(red: 0.92, green: 0.68, blue: 0.08)
    static let marble = Color(uiColor: .systemGroupedBackground)
    static let scrollParchment = Color(red: 0.98, green: 0.92, blue: 0.78)
    static let successGreen = Color(red: 0, green: 0.39, blue: 0)
    static let warningAmber = Color(red: 0.86, green: 0.57, blue: 0)
}

extension Date {
    static func caesars(_ year: Int, _ month: Int, _ day: Int, _ hour: Int) -> Date {
        Calendar.current.date(from: DateComponents(year: year, month: month, day: day, hour: hour)) ?? Date()
    }
}
