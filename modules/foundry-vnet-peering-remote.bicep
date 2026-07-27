param searchVnetName string
param searchVnetId string
param foundryVnetName string
param allowForwardedTraffic bool

resource foundryVnet 'Microsoft.Network/virtualNetworks@2024-05-01' existing = {
  name: foundryVnetName
}

resource foundryToSearch 'Microsoft.Network/virtualNetworks/virtualNetworkPeerings@2024-05-01' = {
  name: 'peer-to-${searchVnetName}'
  parent: foundryVnet
  properties: {
    allowVirtualNetworkAccess: true
    allowForwardedTraffic: allowForwardedTraffic
    allowGatewayTransit: false
    useRemoteGateways: false
    remoteVirtualNetwork: {
      id: searchVnetId
    }
  }
}
