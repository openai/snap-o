package com.openai.snapo.desktop.inspector

import com.openai.snapo.desktop.di.AppScope
import dev.zacsweers.metro.Inject
import dev.zacsweers.metro.SingleIn
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.launch

@SingleIn(AppScope::class)
@Inject
class NetworkInspectorStore(
    private val service: NetworkInspectorService,
    private val scope: CoroutineScope = CoroutineScope(SupervisorJob() + Dispatchers.Default),
) {
    private val _servers = MutableStateFlow<List<NetworkInspectorServerUiModel>>(emptyList())
    val servers: StateFlow<List<NetworkInspectorServerUiModel>> = _servers.asStateFlow()

    private val _items = MutableStateFlow<List<NetworkInspectorListItemUiModel>>(emptyList())
    val items: StateFlow<List<NetworkInspectorListItemUiModel>> = _items.asStateFlow()

    private val _listSortOrder = MutableStateFlow(ListSortOrder.OldestFirst)
    val listSortOrder: StateFlow<ListSortOrder> = _listSortOrder.asStateFlow()

    // Lookups for detail views.
    @Volatile
    private var requestLookup: Map<NetworkInspectorRequestId, NetworkInspectorRequest> = emptyMap()

    @Volatile
    private var webSocketLookup: Map<NetworkInspectorWebSocketId, NetworkInspectorWebSocket> = emptyMap()

    init {
        service.start()

        scope.launch {
            combine(
                service.servers,
                service.requests,
                service.webSockets,
                _listSortOrder,
            ) { servers, requests, webSockets, sortOrder ->
                buildUiState(servers, requests, webSockets, sortOrder)
            }.collect { state ->
                requestLookup = state.requestLookup
                webSocketLookup = state.webSocketLookup
                _servers.value = state.servers
                _items.value = state.items
            }
        }
    }

    fun toggleSortOrder() {
        _listSortOrder.value = when (_listSortOrder.value) {
            ListSortOrder.OldestFirst -> ListSortOrder.NewestFirst
            ListSortOrder.NewestFirst -> ListSortOrder.OldestFirst
        }
    }

    fun setRetainedServerIds(ids: Set<SnapOLinkServerId>) {
        scope.launch {
            service.updateRetainedServers(ids)
        }
    }

    fun clearCompleted() {
        scope.launch {
            service.clearCompletedEntries()
        }
    }

    fun notifyFeatureOpened(feature: String, serverId: SnapOLinkServerId?) {
        service.sendFeatureOpened(feature, serverId)
    }

    fun requestOrNull(id: NetworkInspectorRequestId): NetworkInspectorRequest? = requestLookup[id]

    fun webSocketOrNull(id: NetworkInspectorWebSocketId): NetworkInspectorWebSocket? = webSocketLookup[id]

    private data class UiState(
        val servers: List<NetworkInspectorServerUiModel>,
        val items: List<NetworkInspectorListItemUiModel>,
        val requestLookup: Map<NetworkInspectorRequestId, NetworkInspectorRequest>,
        val webSocketLookup: Map<NetworkInspectorWebSocketId, NetworkInspectorWebSocket>,
    )

    private fun buildUiState(
        servers: List<SnapOLinkServer>,
        requests: List<NetworkInspectorRequest>,
        webSockets: List<NetworkInspectorWebSocket>,
        sortOrder: ListSortOrder,
    ): UiState {
        val serverVms = servers.map(NetworkInspectorServerUiModel::from)
        val requestLookup = requests.associateBy { it.id }
        val webSocketLookup = webSockets.associateBy { it.id }

        val requestSummaries = requests.map(::requestSummary)
        val webSocketSummaries = webSockets.map(::webSocketSummary)

        val combined = buildList {
            addAll(
                requestSummaries.map { summary ->
                    NetworkInspectorListItemUiModel(
                        kind = NetworkInspectorListItemUiModel.Kind.Request(summary),
                        firstSeenAt = summary.firstSeenAt,
                    )
                }
            )
            addAll(
                webSocketSummaries.map { summary ->
                    NetworkInspectorListItemUiModel(
                        kind = NetworkInspectorListItemUiModel.Kind.WebSocket(summary),
                        firstSeenAt = summary.firstSeenAt,
                    )
                }
            )
        }

        val comparator: Comparator<NetworkInspectorListItemUiModel> = when (sortOrder) {
            ListSortOrder.OldestFirst -> compareBy<NetworkInspectorListItemUiModel> { it.firstSeenAt }
                .thenBy { it.id.hashCode() }
            ListSortOrder.NewestFirst -> compareByDescending<NetworkInspectorListItemUiModel> { it.firstSeenAt }
                .thenBy { it.id.hashCode() }
        }

        return UiState(
            servers = serverVms,
            items = combined.sortedWith(comparator),
            requestLookup = requestLookup,
            webSocketLookup = webSocketLookup,
        )
    }
}
