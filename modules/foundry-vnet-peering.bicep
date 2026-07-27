param searchVnetName string
param searchVnetId string
param foundryVnetName string
param foundryVnetResourceGroupName string
param foundryVnetSubscriptionId string
param allowForwardedTraffic bool
param allowGatewayTransitFromSearchToFoundry bool
param useRemoteGatewaysOnSearchToFoundry bool

resource searchVnet 'Microsoft.Network/virtualNetworks@2024-05-01' existing = {
  name: searchVnetName
}

resource foundryVnet 'Microsoft.Network/virtualNetworks@2024-05-01' existing = {
  name: foundryVnetName
  scope: resourceGroup(foundryVnetSubscriptionId, foundryVnetResourceGroupName)
}

resource searchToFoundry 'Microsoft.Network/virtualNetworks/virtualNetworkPeerings@2024-05-01' = {
  name: 'peer-to-${foundryVnetName}'
  parent: searchVnet
  properties: {
    allowVirtualNetworkAccess: true
    allowForwardedTraffic: allowForwardedTraffic
    allowGatewayTransit: allowGatewayTransitFromSearchToFoundry
    useRemoteGateways: useRemoteGatewaysOnSearchToFoundry
    remoteVirtualNetwork: {
      id: foundryVnet.id
    }
  }
}

// The reverse peering lives on the Foundry VNet, which may be in a different
// resource group/subscription. A plain child resource can't cross scopes, so
// this side is deployed as a scoped module instead (BCP165).
module foundryToSearch './foundry-vnet-peering-remote.bicep' = {
  name: 'foundry-to-search-peering'
  scope: resourceGroup(foundryVnetSubscriptionId, foundryVnetResourceGroupName)
  params: {
    searchVnetName: searchVnetName
    searchVnetId: searchVnetId
    foundryVnetName: foundryVnetName
    allowForwardedTraffic: allowForwardedTraffic
  }
}
