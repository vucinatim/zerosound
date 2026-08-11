@preconcurrency import Network

func tcpParameters() -> NWParameters {
  let parameters = NWParameters.tcp
  parameters.includePeerToPeer = true
  if let options = parameters.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options {
    options.noDelay = true
    options.enableKeepalive = true
    options.keepaliveIdle = 3
    options.keepaliveInterval = 1
    options.keepaliveCount = 3
  }
  return parameters
}
