import Foundation
import Testing

@testable import SmartTubeIOS
@testable import SmartTubeIOSCore

// MARK: - Brand Account channel switching
//
// The OAuth token always belongs to the primary account; the selected Brand Account is
// sent as `X-Goog-Pageid` (SmartTube Android's approach, validated live on the TV client).

private final class ChannelStubURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var capturedHeaders: [[String: String]] = []

    override static func canInit(with request: URLRequest) -> Bool { true }
    override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.capturedHeaders.append(request.allHTTPHeaderFields ?? [:])
        guard let url = request.url,
            let response = HTTPURLResponse(
                url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])
        else { return }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("{}".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private func accountItem(
    name: String,
    pageId: String?,
    avatar: String? = nil,
    nameAsRuns: Bool = false
) -> [String: Any] {
    var item: [String: Any] = [
        "accountName": nameAsRuns ? ["runs": [["text": name]]] : ["simpleText": name]
    ]
    if let avatar { item["accountPhoto"] = ["thumbnails": [["url": "//small"], ["url": avatar]]] }
    if let pageId {
        item["serviceEndpoint"] = [
            "selectActiveIdentityEndpoint": ["supportedTokens": [["pageIdToken": ["pageId": pageId]]]]
        ]
    }
    return ["accountItem": item]
}

private func accountsList(_ items: [[String: Any]]) -> [String: Any] {
    [
        "contents": [
            ["accountSectionListRenderer": ["contents": [["accountItemSectionRenderer": ["contents": items]]]]]
        ]
    ]
}

@Suite("Brand Account — accounts_list parsing")
struct BrandAccountParsingTests {

    // deve listar a conta principal e os Brand Accounts, com pageId nil só na principal
    @Test("should list the primary account and Brand Accounts with a nil pageId only on the primary")
    func listsPrimaryAndBrandAccounts() {
        let json = accountsList([
            accountItem(name: "Brand Channel", pageId: "100000000000000000001"),
            accountItem(name: "Primary User", pageId: nil),
        ])

        let channels = YouTubeChannel.list(fromAccountsList: json)

        #expect(channels.map(\.name) == ["Brand Channel", "Primary User"])
        #expect(channels[0].pageId == "100000000000000000001")
        #expect(channels[0].isPrimary == false)
        #expect(channels[1].pageId == nil)
        #expect(channels[1].isPrimary)
    }

    // deve ler o nome em runs e normalizar o avatar protocol-relative para https
    @Test("should read the name from runs and normalize a protocol-relative avatar to https")
    func readsRunsNameAndNormalizesAvatar() {
        let json = accountsList([
            accountItem(name: "Cooking", pageId: "1", avatar: "//yt3.ggpht.com/a.jpg", nameAsRuns: true)
        ])

        let channel = YouTubeChannel.list(fromAccountsList: json).first

        #expect(channel?.name == "Cooking")
        #expect(channel?.avatarURL == URL(string: "https://yt3.ggpht.com/a.jpg"))
    }

    // deve retornar lista vazia quando a resposta não tem a estrutura esperada
    @Test("should return an empty list when the response does not have the expected shape")
    func returnsEmptyForMalformedResponse() {
        #expect(YouTubeChannel.list(fromAccountsList: [:]).isEmpty)
        #expect(YouTubeChannel.list(fromAccountsList: ["contents": "unexpected"]).isEmpty)
    }

    // deve ignorar item de conta sem nome
    @Test("should skip an account item without a name")
    func skipsItemWithoutName() {
        let json = accountsList([["accountItem": ["isSelected": true]], accountItem(name: "Watch", pageId: "2")])

        #expect(YouTubeChannel.list(fromAccountsList: json).map(\.name) == ["Watch"])
    }
}

@Suite("Brand Account — X-Goog-Pageid on requests", .serialized)
struct BrandAccountRequestHeaderTests {

    private func makeAPI(authToken: String?, activeChannel: ActiveChannel) -> InnerTubeAPI {
        ChannelStubURLProtocol.capturedHeaders = []
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ChannelStubURLProtocol.self]
        let session = URLSession(configuration: config)
        return InnerTubeAPI(authToken: authToken, session: session, activeChannel: activeChannel)
    }

    // deve enviar X-Goog-Pageid junto com o Bearer quando um Brand Account está ativo
    @Test("should send X-Goog-Pageid along with the Bearer token when a Brand Account is active")
    func sendsPageIdWithBearer() async {
        let channel = ActiveChannel()
        channel.set(pageId: "100000000000000000001")
        let api = makeAPI(authToken: "fake-token", activeChannel: channel)

        _ = try? await api.fetchSubscriptions()

        let headers = ChannelStubURLProtocol.capturedHeaders.first
        #expect(headers?["Authorization"] == "Bearer fake-token")
        #expect(headers?["X-Goog-Pageid"] == "100000000000000000001")
    }

    // não deve enviar X-Goog-Pageid quando a conta principal está ativa
    @Test("should not send X-Goog-Pageid when the primary account is active")
    func omitsPageIdForPrimary() async {
        let api = makeAPI(authToken: "fake-token", activeChannel: ActiveChannel())

        _ = try? await api.fetchSubscriptions()

        let headers = ChannelStubURLProtocol.capturedHeaders.first
        #expect(headers?["Authorization"] == "Bearer fake-token")
        #expect(headers?["X-Goog-Pageid"] == nil)
    }

    // não deve enviar X-Goog-Pageid em requisição sem autenticação
    @Test("should not send X-Goog-Pageid on an unauthenticated request")
    func omitsPageIdWhenUnauthenticated() async {
        let channel = ActiveChannel()
        channel.set(pageId: "100000000000000000001")
        let api = makeAPI(authToken: nil, activeChannel: channel)

        _ = try? await api.fetchHome()

        let headers = ChannelStubURLProtocol.capturedHeaders.first
        #expect(headers != nil)
        #expect(headers?["Authorization"] == nil)
        #expect(headers?["X-Goog-Pageid"] == nil)
    }

    // deve usar o novo canal na requisição seguinte após a troca, sem recriar a API
    @Test("should use the new channel on the next request after switching, without recreating the API")
    func appliesSwitchOnNextRequest() async {
        let channel = ActiveChannel()
        channel.set(pageId: "111")
        let api = makeAPI(authToken: "fake-token", activeChannel: channel)

        _ = try? await api.fetchSubscriptions()
        channel.set(pageId: "222")
        _ = try? await api.fetchSubscriptions()
        channel.set(pageId: nil)
        _ = try? await api.fetchSubscriptions()

        #expect(ChannelStubURLProtocol.capturedHeaders.map { $0["X-Goog-Pageid"] } == ["111", "222", nil])
    }
}

@Suite("Brand Account — pageId persistence")
struct BrandAccountPersistenceTests {

    // deve persistir o pageId no Keychain entre instâncias do TokenManager
    @Test("should persist the pageId in the Keychain across TokenManager instances")
    func persistsPageId() async {
        let service = "test-tm-pageid-\(UUID().uuidString)"
        let tm = TokenManager(keychainService: service)

        await tm.setPageId("100000000000000000001")

        #expect(TokenManager(keychainService: service).initialSnapshot.pageId == "100000000000000000001")
        await tm.clearToken()
    }

    // deve apagar o pageId no logout
    @Test("should remove the pageId on sign-out")
    func clearTokenRemovesPageId() async {
        let service = "test-tm-pageid-clear-\(UUID().uuidString)"
        let tm = TokenManager(keychainService: service)
        await tm.setPageId("222")

        await tm.clearToken()

        #expect(await tm.currentPageId() == nil)
        #expect(TokenManager(keychainService: service).initialSnapshot.pageId == nil)
    }

    // deve voltar para a conta principal ao gravar pageId nil
    @Test("should go back to the primary account when storing a nil pageId")
    func nilPageIdRemovesEntry() async {
        let service = "test-tm-pageid-nil-\(UUID().uuidString)"
        let tm = TokenManager(keychainService: service)
        await tm.setPageId("333")

        await tm.setPageId(nil)

        #expect(TokenManager(keychainService: service).initialSnapshot.pageId == nil)
        await tm.clearToken()
    }
}

// AuthService writes to ActiveChannel.shared, so these run serially and reset it afterwards.
@MainActor
@Suite("Brand Account — AuthService channel switch and sign-out", .serialized)
struct BrandAccountAuthServiceTests {

    private final class NotificationCounter: @unchecked Sendable {
        var count = 0
    }

    private let primary = YouTubeChannel(name: "Primary User", avatarURL: nil, pageId: nil)
    private let brand = YouTubeChannel(name: "Brand Channel", avatarURL: nil, pageId: "100000000000000000001")

    private func countChannelChanges(during action: () -> Void) -> Int {
        let counter = NotificationCounter()
        let token = NotificationCenter.default.addObserver(
            forName: .activeChannelDidChange, object: nil, queue: nil
        ) { _ in counter.count += 1 }
        action()
        NotificationCenter.default.removeObserver(token)
        return counter.count
    }

    // deve disparar activeChannelDidChange ao trocar para um Brand Account diferente do ativo
    @Test("should post activeChannelDidChange when switching to a different Brand Account")
    func postsChangeOnSwitch() {
        let auth = AuthService()
        auth.applyChannels([primary, brand])
        defer { auth.resetChannels() }

        let changes = countChannelChanges { auth.selectChannel(brand) }

        #expect(changes == 1)
        #expect(auth.activePageId == brand.pageId)
    }

    // não deve disparar activeChannelDidChange ao selecionar o canal que já está ativo
    @Test("should not post activeChannelDidChange when selecting the already active channel")
    func skipsChangeForActiveChannel() {
        let auth = AuthService()
        auth.applyChannels([primary, brand])
        auth.selectChannel(brand)
        defer { auth.resetChannels() }

        let changes = countChannelChanges { auth.selectChannel(brand) }

        #expect(changes == 0)
    }

    // deve limpar o canal selecionado no logout e enviar a próxima requisição sem X-Goog-Pageid
    @Test("should clear the selected channel on sign-out and send the next request without X-Goog-Pageid")
    func signOutClearsSelectedChannel() async {
        let auth = AuthService()
        auth.applyChannels([primary, brand])
        auth.selectChannel(brand)

        auth.signOut()

        #expect(auth.activePageId == nil)
        #expect(auth.channels.isEmpty)
        #expect(ActiveChannel.shared.pageId == nil)

        ChannelStubURLProtocol.capturedHeaders = []
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ChannelStubURLProtocol.self]
        let session = URLSession(configuration: config)
        let api = InnerTubeAPI(authToken: "fake-token", session: session, activeChannel: .shared)
        _ = try? await api.fetchSubscriptions()

        #expect(ChannelStubURLProtocol.capturedHeaders.first?["X-Goog-Pageid"] == nil)
    }
}
