import Foundation
#if os(macOS)
    import PostboxMac
    import SwiftSignalKitMac
    import MtProtoKitMac
#else
    import Postbox
    import SwiftSignalKit
    import MtProtoKitDynamic
#endif

private func pendingWebpages(entries: [MessageHistoryEntry]) -> Set<MessageId> {
    var messageIds = Set<MessageId>()
    for case let .MessageEntry(message, _, _) in entries {
        for media in message.media {
            if let media = media as? TelegramMediaWebpage {
                if case .Pending = media.content {
                    messageIds.insert(message.id)
                }
                break
            }
        }
    }
    return messageIds
}

private func fetchWebpage(account: Account, messageId: MessageId) -> Signal<Void, NoError> {
    return account.postbox.loadedPeerWithId(messageId.peerId)
        |> take(1)
        |> mapToSignal { peer in
            if let inputPeer = apiInputPeer(peer) {
                let messages: Signal<Api.messages.Messages, MTRpcError>
                switch inputPeer {
                    case let .inputPeerChannel(channelId, accessHash):
                        messages = account.network.request(Api.functions.channels.getMessages(channel: Api.InputChannel.inputChannel(channelId: channelId, accessHash: accessHash), id: [messageId.id]))
                    default:
                        messages = account.network.request(Api.functions.messages.getMessages(id: [messageId.id]))
                }
                return messages
                    |> retryRequest
                    |> mapToSignal { result in
                        let messages: [Api.Message]
                        let chats: [Api.Chat]
                        let users: [Api.User]
                        switch result {
                            case let .messages(messages: apiMessages, chats: apiChats, users: apiUsers):
                                messages = apiMessages
                                chats = apiChats
                                users = apiUsers
                            case let .messagesSlice(_, messages: apiMessages, chats: apiChats, users: apiUsers):
                                messages = apiMessages
                                chats = apiChats
                                users = apiUsers
                            case let .channelMessages(_, _, _, apiMessages, apiChats, apiUsers):
                                messages = apiMessages
                                chats = apiChats
                                users = apiUsers
                        }
                        
                        return account.postbox.modify { modifier -> Void in
                            var peers: [Peer] = []
                            var peerPresences: [PeerId: PeerPresence] = [:]
                            for chat in chats {
                                if let groupOrChannel = parseTelegramGroupOrChannel(chat: chat) {
                                    peers.append(groupOrChannel)
                                }
                            }
                            for user in users {
                                let telegramUser = TelegramUser(user: user)
                                peers.append(telegramUser)
                                if let presence = TelegramUserPresence(apiUser: user) {
                                    peerPresences[telegramUser.id] = presence
                                }
                            }
                            
                            for message in messages {
                                if let storeMessage = StoreMessage(apiMessage: message) {
                                    var webpage: TelegramMediaWebpage?
                                    for media in storeMessage.media {
                                        if let media = media as? TelegramMediaWebpage {
                                            webpage = media
                                        }
                                    }
                                    
                                    if let webpage = webpage {
                                        modifier.updateMedia(webpage.webpageId, update: webpage)
                                    } else {
                                        if let previousMessage = modifier.getMessage(messageId) {
                                            for media in previousMessage.media {
                                                if let media = media as? TelegramMediaWebpage {
                                                    modifier.updateMedia(media.webpageId, update: nil)
                                                    
                                                    break
                                                }
                                            }
                                        }
                                    }
                                    break
                                }
                            }
                            
                            modifier.updatePeers(peers, update: { _, updated -> Peer in
                                return updated
                            })
                            modifier.updatePeerPresences(peerPresences)
                        }
                    }
            } else {
                return .complete()
            }
        }
}

private final class PeerCachedDataContext {
    var viewIds = Set<Int32>()
    var timestamp: Double?
    var referenceData: CachedPeerData?
    let disposable = MetaDisposable()
    
    deinit {
        self.disposable.dispose()
    }
}

public final class AccountViewTracker {
    weak var account: Account?
    private let queue = Queue()
    private var nextViewId: Int32 = 0
    
    private var viewPendingWebpageMessageIds: [Int32: Set<MessageId>] = [:]
    private var pendingWebpageMessageIds: [MessageId: Int] = [:]
    private var webpageDisposables: [MessageId: Disposable] = [:]
    
    private var cachedDataContexts: [PeerId: PeerCachedDataContext] = [:]
    
    init(account: Account) {
        self.account = account
    }
    
    deinit {
        
    }
    
    private func updatePendingWebpages(viewId: Int32, messageIds: Set<MessageId>) {
        self.queue.async {
            var addedMessageIds: [MessageId] = []
            var removedMessageIds: [MessageId] = []
            
            let viewMessageIds: Set<MessageId> = self.viewPendingWebpageMessageIds[viewId] ?? Set()
            
            let viewAddedMessageIds = messageIds.subtracting(viewMessageIds)
            let viewRemovedMessageIds = viewMessageIds.subtracting(messageIds)
            for messageId in viewAddedMessageIds {
                if let count = self.pendingWebpageMessageIds[messageId] {
                    self.pendingWebpageMessageIds[messageId] = count + 1
                } else {
                    self.pendingWebpageMessageIds[messageId] = 1
                    addedMessageIds.append(messageId)
                }
            }
            for messageId in viewRemovedMessageIds {
                if let count = self.pendingWebpageMessageIds[messageId] {
                    if count == 1 {
                        self.pendingWebpageMessageIds.removeValue(forKey: messageId)
                        removedMessageIds.append(messageId)
                    } else {
                        self.pendingWebpageMessageIds[messageId] = count - 1
                    }
                } else {
                    assertionFailure()
                }
            }
            
            if messageIds.isEmpty {
                self.viewPendingWebpageMessageIds.removeValue(forKey: viewId)
            } else {
                self.viewPendingWebpageMessageIds[viewId] = messageIds
            }
            
            for messageId in removedMessageIds {
                if let disposable = self.webpageDisposables.removeValue(forKey: messageId) {
                    disposable.dispose()
                }
            }
            
            if let account = self.account {
                for messageId in addedMessageIds {
                    if self.webpageDisposables[messageId] == nil {
                        self.webpageDisposables[messageId] = fetchWebpage(account: account, messageId: messageId).start(completed: { [weak self] in
                            if let strongSelf = self {
                                strongSelf.queue.async {
                                    strongSelf.webpageDisposables.removeValue(forKey: messageId)
                                }
                            }
                        })
                    } else {
                        assertionFailure()
                    }
                }
            }
        }
    }
    
    private func updateCachedPeerData(peerId: PeerId, viewId: Int32, referenceData: CachedPeerData?) {
        self.queue.async {
            let context: PeerCachedDataContext
            var dataUpdated = false
            if let existingContext = self.cachedDataContexts[peerId] {
                context = existingContext
                context.referenceData = referenceData
                if context.timestamp == nil || abs(CFAbsoluteTimeGetCurrent() - context.timestamp!) > 60.0 * 60.0 {
                    dataUpdated = true
                }
            } else {
                context = PeerCachedDataContext()
                context.referenceData = referenceData
                self.cachedDataContexts[peerId] = context
                if context.referenceData == nil || context.timestamp == nil || abs(CFAbsoluteTimeGetCurrent() - context.timestamp!) > 60.0 * 60.0 {
                    context.timestamp = CFAbsoluteTimeGetCurrent()
                    dataUpdated = true
                }
            }
            context.viewIds.insert(viewId)
            
            if dataUpdated {
                if let account = self.account {
                    context.disposable.set(fetchAndUpdateCachedPeerData(peerId: peerId, network: account.network, postbox: account.postbox).start())
                }
            }
        }
    }
    
    private func removePeerView(peerId: PeerId, id: Int32) {
        self.queue.async {
            if let context = self.cachedDataContexts[peerId] {
                context.viewIds.remove(id)
                if context.viewIds.isEmpty {
                    context.disposable.set(nil)
                    context.referenceData = nil
                }
            }
        }
    }
    
    func wrappedMessageHistorySignal(_ signal: Signal<(MessageHistoryView, ViewUpdateType), NoError>) -> Signal<(MessageHistoryView, ViewUpdateType), NoError> {
        return withState(signal, { [weak self] () -> Int32 in
            if let strongSelf = self {
                return OSAtomicIncrement32(&strongSelf.nextViewId)
            } else {
                return -1
            }
        }, next: { [weak self] next, viewId in
            if let strongSelf = self {
                let messageIds = pendingWebpages(entries: next.0.entries)
                strongSelf.updatePendingWebpages(viewId: viewId, messageIds: messageIds)
            }
        }, disposed: { [weak self] viewId in
            if let strongSelf = self {
                strongSelf.updatePendingWebpages(viewId: viewId, messageIds: [])
            }
        })
    }
    
    public func aroundUnreadMessageHistoryViewForPeerId(_ peerId: PeerId, count: Int, tagMask: MessageTags? = nil) -> Signal<(MessageHistoryView, ViewUpdateType), NoError> {
        if let account = self.account {
            let signal = account.postbox.aroundUnreadMessageHistoryViewForPeerId(peerId, count: count, tagMask: tagMask)
            return wrappedMessageHistorySignal(signal)
        } else {
            return .never()
        }
    }
    
    public func aroundIdMessageHistoryViewForPeerId(_ peerId: PeerId, count: Int, messageId: MessageId, tagMask: MessageTags? = nil) -> Signal<(MessageHistoryView, ViewUpdateType), NoError> {
        if let account = self.account {
            let signal = account.postbox.aroundIdMessageHistoryViewForPeerId(peerId, count: count, messageId: messageId, tagMask: tagMask)
            return wrappedMessageHistorySignal(signal)
        } else {
            return .never()
        }
    }
    
    public func aroundMessageHistoryViewForPeerId(_ peerId: PeerId, index: MessageIndex, count: Int, anchorIndex: MessageIndex, fixedCombinedReadState: CombinedPeerReadState?, tagMask: MessageTags? = nil) -> Signal<(MessageHistoryView, ViewUpdateType), NoError> {
        if let account = self.account {
            let signal = account.postbox.aroundMessageHistoryViewForPeerId(peerId, index: index, count: count, anchorIndex: anchorIndex, fixedCombinedReadState: fixedCombinedReadState, tagMask: tagMask)
            return wrappedMessageHistorySignal(signal)
        } else {
            return .never()
        }
    }
    
    func wrappedPeerViewSignal(peerId: PeerId, signal: Signal<PeerView, NoError>) -> Signal<PeerView, NoError> {
        return withState(signal, { [weak self] () -> Int32 in
            if let strongSelf = self {
                return OSAtomicIncrement32(&strongSelf.nextViewId)
            } else {
                return -1
            }
        }, next: { [weak self] next, viewId in
            if let strongSelf = self {
                strongSelf.updateCachedPeerData(peerId: peerId, viewId: viewId, referenceData: next.cachedData)
            }
        }, disposed: { [weak self] viewId in
            if let strongSelf = self {
                strongSelf.removePeerView(peerId: peerId, id: viewId)
            }
        })
    }
    
    public func peerView(_ peerId: PeerId) -> Signal<PeerView, NoError> {
        if let account = self.account {
            return wrappedPeerViewSignal(peerId: peerId, signal: account.postbox.peerView(id: peerId))
        } else {
            return .never()
        }
    }
}