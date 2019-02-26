//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2017-2018 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import XCTest
import NIO
import NIOHTTP1
@testable import NIOHPACK       // for HPACKHeaders initializers
@testable import NIOHTTP2

private extension Channel {
    /// Adds a simple no-op `HTTP2StreamMultiplexer` to the pipeline.
    func addNoOpMultiplexer(mode: NIOHTTP2Handler.ParserMode) {
        XCTAssertNoThrow(try self.pipeline.addHandler(HTTP2StreamMultiplexer(mode: mode, channel: self) { (channel, streamID) in
            self.eventLoop.makeSucceededFuture(())
        }).wait())
    }
}

private struct MyError: Error { }


/// A handler that asserts the frames received match the expected set.
final class FrameExpecter: ChannelInboundHandler {
    typealias InboundIn = HTTP2Frame
    typealias OutboundOut = HTTP2Frame

    private let expectedFrames: [HTTP2Frame]
    private var actualFrames: [HTTP2Frame] = []
    private var inactive = false

    init(expectedFrames: [HTTP2Frame]) {
        self.expectedFrames = expectedFrames
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        XCTAssertFalse(self.inactive)
        let frame = self.unwrapInboundIn(data)
        self.actualFrames.append(frame)
    }

    func channelInactive(context: ChannelHandlerContext) {
        XCTAssertFalse(self.inactive)
        self.inactive = true

        XCTAssertEqual(self.expectedFrames.count, self.actualFrames.count)

        for (idx, expectedFrame) in self.expectedFrames.enumerated() {
            let actualFrame = self.actualFrames[idx]
            expectedFrame.assertFrameMatches(this: actualFrame)
        }
    }
}


// A handler that keeps track of the writes made on a channel. Used to work around the limitations
// in `EmbeddedChannel`.
final class FrameWriteRecorder: ChannelOutboundHandler {
    typealias OutboundIn = HTTP2Frame
    typealias OutboundOut = HTTP2Frame

    var flushedWrites: [HTTP2Frame] = []
    private var unflushedWrites: [HTTP2Frame] = []

    func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        self.unflushedWrites.append(self.unwrapOutboundIn(data))
        context.write(data, promise: promise)
    }

    func flush(context: ChannelHandlerContext) {
        self.flushedWrites.append(contentsOf: self.unflushedWrites)
        self.unflushedWrites = []
        context.flush()
    }
}


/// A handler that keeps track of all reads made on a channel.
final class InboundFrameRecorder: ChannelInboundHandler {
    typealias InboundIn = HTTP2Frame

    var receivedFrames: [HTTP2Frame] = []

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        self.receivedFrames.append(self.unwrapInboundIn(data))
    }
}


/// A handler that tracks the number of times read() was called on the channel.
final class ReadCounter: ChannelOutboundHandler {
    typealias OutboundIn = Any
    typealias OutboundOut = Any

    var readCount = 0

    func read(context: ChannelHandlerContext) {
        readCount += 1
    }
}


/// A channel handler that succeeds a promise when removed from
/// a pipeline.
final class HandlerRemovedHandler: ChannelInboundHandler {
    typealias InboundIn = HTTP2Frame

    let removedPromise: EventLoopPromise<Void>

    init(removedPromise: EventLoopPromise<Void>) {
        self.removedPromise = removedPromise
    }

    func handlerRemoved(context: ChannelHandlerContext) {
        self.removedPromise.succeed(())
    }
}


/// A channel handler that succeeds a promise when its channel becomes active.
final class ActiveHandler: ChannelInboundHandler {
    typealias InboundIn = Any

    let activatedPromise: EventLoopPromise<Void>

    init(activatedPromise: EventLoopPromise<Void>) {
        self.activatedPromise = activatedPromise
    }

    func handlerAdded(context: ChannelHandlerContext) {
        if context.channel.isActive {
            self.activatedPromise.succeed(())
        }
    }

    func channelActive(context: ChannelHandlerContext) {
        self.activatedPromise.succeed(())
    }
}


final class HTTP2StreamMultiplexerTests: XCTestCase {
    var channel: EmbeddedChannel!

    override func setUp() {
        self.channel = EmbeddedChannel()
    }

    override func tearDown() {
        self.channel = nil
    }

    func testMultiplexerIgnoresFramesOnStream0() throws {
        self.channel.addNoOpMultiplexer(mode: .server)

        let simplePingFrame = HTTP2Frame(streamID: .rootStream, payload: .ping(HTTP2PingData(withInteger: 5), ack: false))
        XCTAssertNoThrow(try self.channel.writeInbound(simplePingFrame))
        XCTAssertNoThrow(try self.channel.assertReceivedFrame().assertFrameMatches(this: simplePingFrame))

        XCTAssertNoThrow(try self.channel.finish())
    }

    func testHeadersFramesCreateNewChannels() throws {
        var channelCount = 0
        let multiplexer = HTTP2StreamMultiplexer(mode: .server, channel: self.channel) { (channel, _) in
            channelCount += 1
            return channel.close()
        }
        XCTAssertNoThrow(try self.channel.pipeline.addHandler(multiplexer).wait())

        // Let's send a bunch of headers frames.
        for streamID in stride(from: 1, to: 100, by: 2) {
            let frame = HTTP2Frame(streamID: HTTP2StreamID(streamID), payload: .headers(.init(headers: HPACKHeaders())))
            XCTAssertNoThrow(try self.channel.writeInbound(frame))
        }

        XCTAssertEqual(channelCount, 50)
        XCTAssertNoThrow(try self.channel.finish())
    }

    func testChannelsCloseThemselvesWhenToldTo() throws {
        var completedChannelCount = 0
        var closeFutures: [EventLoopFuture<Void>] = []
        let multiplexer = HTTP2StreamMultiplexer(mode: .server, channel: self.channel) { (channel, _) in
            closeFutures.append(channel.closeFuture)
            channel.closeFuture.whenSuccess { completedChannelCount += 1 }
            return channel.eventLoop.makeSucceededFuture(())
        }
        XCTAssertNoThrow(try self.channel.pipeline.addHandler(multiplexer).wait())

        // Let's send a bunch of headers frames with endStream on them. This should open some streams.
        let streamIDs = stride(from: 1, to: 100, by: 2).map { HTTP2StreamID($0) }
        for streamID in streamIDs {
            let frame = HTTP2Frame(streamID: streamID, payload: .headers(.init(headers: HPACKHeaders(), endStream: true)))
            XCTAssertNoThrow(try self.channel.writeInbound(frame))
        }
        XCTAssertEqual(completedChannelCount, 0)

        // Now we send them all a clean exit.
        for streamID in streamIDs {
            let event = StreamClosedEvent(streamID: streamID, reason: nil)
            self.channel.pipeline.fireUserInboundEventTriggered(event)
        }
        (self.channel.eventLoop as! EmbeddedEventLoop).run()

        // At this stage all the promises should be completed.
        XCTAssertEqual(completedChannelCount, 50)
        XCTAssertNoThrow(try self.channel.finish())
    }

    func testChannelsCloseAfterResetStreamFrameFirstThenEvent() throws {
        var closeError: Error? = nil

        XCTAssertNoThrow(try self.channel.connect(to: SocketAddress(unixDomainSocketPath: "/whatever"), promise: nil))

        // First, set up the frames we want to send/receive.
        let streamID = HTTP2StreamID(1)
        let frame = HTTP2Frame(streamID: streamID, payload: .headers(.init(headers: HPACKHeaders(), endStream: true)))
        let rstStreamFrame = HTTP2Frame(streamID: streamID, payload: .rstStream(.cancel))

        let multiplexer = HTTP2StreamMultiplexer(mode: .server, channel: self.channel) { (channel, _) in
            XCTAssertNil(closeError)
            channel.closeFuture.whenFailure { closeError = $0 }
            return channel.pipeline.addHandler(FrameExpecter(expectedFrames: [frame, rstStreamFrame]))
        }
        XCTAssertNoThrow(try self.channel.pipeline.addHandler(multiplexer).wait())

        // Let's open the stream up.
        XCTAssertNoThrow(try self.channel.writeInbound(frame))
        XCTAssertNil(closeError)

        // Now we can send a RST_STREAM frame.
        XCTAssertNoThrow(try self.channel.writeInbound(rstStreamFrame))

        // Now we send the user event.
        let userEvent = StreamClosedEvent(streamID: streamID, reason: .cancel)
        self.channel.pipeline.fireUserInboundEventTriggered(userEvent)
        (self.channel.eventLoop as! EmbeddedEventLoop).run()

        // At this stage the stream should be closed with the appropriate error code.
        XCTAssertEqual(closeError as? NIOHTTP2Errors.StreamClosed,
                       NIOHTTP2Errors.StreamClosed(streamID: streamID, errorCode: .cancel))
        XCTAssertNoThrow(try self.channel.finish())
    }

    func testChannelsCloseAfterGoawayFrameFirstThenEvent() throws {
        var closeError: Error? = nil

        XCTAssertNoThrow(try self.channel.connect(to: SocketAddress(unixDomainSocketPath: "/whatever"), promise: nil))

        // First, set up the frames we want to send/receive.
        let streamID = HTTP2StreamID(1)
        let frame = HTTP2Frame(streamID: streamID, payload: .headers(.init(headers: HPACKHeaders(), endStream: true)))
        let goAwayFrame = HTTP2Frame(streamID: .rootStream, payload: .goAway(lastStreamID: .rootStream, errorCode: .http11Required, opaqueData: nil))

        let multiplexer = HTTP2StreamMultiplexer(mode: .server, channel: self.channel) { (channel, _) in
            XCTAssertNil(closeError)
            channel.closeFuture.whenFailure { closeError = $0 }
            // The channel won't see the goaway frame.
            return channel.pipeline.addHandler(FrameExpecter(expectedFrames: [frame]))
        }
        XCTAssertNoThrow(try self.channel.pipeline.addHandler(multiplexer).wait())

        // Let's open the stream up.
        XCTAssertNoThrow(try self.channel.writeInbound(frame))
        XCTAssertNil(closeError)

        // Now we can send a GOAWAY frame. This will close the stream.
        XCTAssertNoThrow(try self.channel.writeInbound(goAwayFrame))

        // Now we send the user event.
        let userEvent = StreamClosedEvent(streamID: streamID, reason: .refusedStream)
        self.channel.pipeline.fireUserInboundEventTriggered(userEvent)
        (self.channel.eventLoop as! EmbeddedEventLoop).run()

        // At this stage the stream should be closed with the appropriate manufactured error code.
        XCTAssertEqual(closeError as? NIOHTTP2Errors.StreamClosed,
                       NIOHTTP2Errors.StreamClosed(streamID: streamID, errorCode: .refusedStream))
        XCTAssertNoThrow(try self.channel.finish())
    }

    func testFramesForUnknownStreamsAreReported() throws {
        self.channel.addNoOpMultiplexer(mode: .server)

        var buffer = self.channel.allocator.buffer(capacity: 12)
        buffer.writeStaticString("Hello, world!")
        let streamID = HTTP2StreamID(5)
        let dataFrame = HTTP2Frame(streamID: streamID, payload: .data(.init(data: .byteBuffer(buffer))))

        do {
            try self.channel.writeInbound(dataFrame)
            XCTFail("Did not throw")
        } catch let error as NIOHTTP2Errors.NoSuchStream {
            XCTAssertEqual(error.streamID, streamID)
        }
        self.channel.assertNoFramesReceived()

        XCTAssertNoThrow(try self.channel.finish())
    }

    func testFramesForClosedStreamsAreReported() throws {
        self.channel.addNoOpMultiplexer(mode: .server)

        // We need to open the stream, then close it. A headers frame will open it, and then the closed event will close it.
        let streamID = HTTP2StreamID(5)
        let frame = HTTP2Frame(streamID: streamID, payload: .headers(.init(headers: HPACKHeaders())))
        XCTAssertNoThrow(try self.channel.writeInbound(frame))
        let userEvent = StreamClosedEvent(streamID: streamID, reason: nil)
        self.channel.pipeline.fireUserInboundEventTriggered(userEvent)
        (self.channel.eventLoop as! EmbeddedEventLoop).run()

        // Ok, now we can send a DATA frame for the now-closed stream.
        var buffer = self.channel.allocator.buffer(capacity: 12)
        buffer.writeStaticString("Hello, world!")
        let dataFrame = HTTP2Frame(streamID: streamID, payload: .data(.init(data: .byteBuffer(buffer))))

        do {
            try self.channel.writeInbound(dataFrame)
            XCTFail("Did not throw")
        } catch let error as NIOHTTP2Errors.NoSuchStream {
            XCTAssertEqual(error.streamID, streamID)
        }
        self.channel.assertNoFramesReceived()

        XCTAssertNoThrow(try self.channel.finish())
    }

    func testClosingIdleChannels() throws {
        let frameReceiver = FrameWriteRecorder()
        let multiplexer = HTTP2StreamMultiplexer(mode: .server, channel: self.channel) { (channel, _) in
            return channel.close()
        }
        XCTAssertNoThrow(try self.channel.pipeline.addHandler(frameReceiver).wait())
        XCTAssertNoThrow(try self.channel.pipeline.addHandler(multiplexer).wait())

        // Let's send a bunch of headers frames. These will all be answered by RST_STREAM frames.
        let streamIDs = stride(from: 1, to: 100, by: 2).map { HTTP2StreamID($0) }
        for streamID in streamIDs {
            let frame = HTTP2Frame(streamID: streamID, payload: .headers(.init(headers: HPACKHeaders())))
            XCTAssertNoThrow(try self.channel.writeInbound(frame))
        }

        let expectedFrames = streamIDs.map { HTTP2Frame(streamID: $0, payload: .rstStream(.cancel)) }
        XCTAssertEqual(expectedFrames.count, frameReceiver.flushedWrites.count)
        for (idx, expectedFrame) in expectedFrames.enumerated() {
            let actualFrame = frameReceiver.flushedWrites[idx]
            expectedFrame.assertFrameMatches(this: actualFrame)
        }
        XCTAssertNoThrow(try self.channel.finish())
    }

    func testClosingActiveChannels() throws {
        let frameReceiver = FrameWriteRecorder()
        let channelPromise: EventLoopPromise<Channel> = self.channel.eventLoop.makePromise()
        let multiplexer = HTTP2StreamMultiplexer(mode: .server, channel: self.channel) { (channel, _) in
            channelPromise.succeed(channel)
            return channel.eventLoop.makeSucceededFuture(())
        }
        XCTAssertNoThrow(try self.channel.pipeline.addHandler(frameReceiver).wait())
        XCTAssertNoThrow(try self.channel.pipeline.addHandler(multiplexer).wait())


        XCTAssertNoThrow(try self.channel.connect(to: SocketAddress(unixDomainSocketPath: "/whatever"), promise: nil))

        // Let's send a headers frame to open the stream.
        let streamID = HTTP2StreamID(1)
        let frame = HTTP2Frame(streamID: streamID, payload: .headers(.init(headers: HPACKHeaders())))
        XCTAssertNoThrow(try self.channel.writeInbound(frame))

        // The channel should now be active.
        let childChannel = try channelPromise.futureResult.wait()
        XCTAssertTrue(childChannel.isActive)

        // Now we close it. This triggers a RST_STREAM frame.
        childChannel.close(promise: nil)
        XCTAssertEqual(frameReceiver.flushedWrites.count, 1)
        frameReceiver.flushedWrites[0].assertRstStreamFrame(streamID: streamID, errorCode: .cancel)

        XCTAssertNoThrow(try self.channel.finish())
    }

    func testClosePromiseIsSatisfiedWithTheEvent() throws {
        let frameReceiver = FrameWriteRecorder()
        let channelPromise: EventLoopPromise<Channel> = self.channel.eventLoop.makePromise()
        let multiplexer = HTTP2StreamMultiplexer(mode: .server, channel: self.channel) { (channel, _) in
            channelPromise.succeed(channel)
            return channel.eventLoop.makeSucceededFuture(())
        }
        XCTAssertNoThrow(try self.channel.pipeline.addHandler(frameReceiver).wait())
        XCTAssertNoThrow(try self.channel.pipeline.addHandler(multiplexer).wait())


        XCTAssertNoThrow(try self.channel.connect(to: SocketAddress(unixDomainSocketPath: "/whatever"), promise: nil))

        // Let's send a headers frame to open the stream.
        let streamID = HTTP2StreamID(1)
        let frame = HTTP2Frame(streamID: streamID, payload: .headers(.init(headers: HPACKHeaders())))
        XCTAssertNoThrow(try self.channel.writeInbound(frame))

        // The channel should now be active.
        let childChannel = try channelPromise.futureResult.wait()
        XCTAssertTrue(childChannel.isActive)

        // Now we close it. This triggers a RST_STREAM frame. The channel will not be closed at this time.
        var closed = false
        childChannel.close().whenComplete { _ in closed = true }
        XCTAssertEqual(frameReceiver.flushedWrites.count, 1)
        frameReceiver.flushedWrites[0].assertRstStreamFrame(streamID: streamID, errorCode: .cancel)
        XCTAssertFalse(closed)

        // Now send the stream closed event. This will satisfy the close promise.
        let userEvent = StreamClosedEvent(streamID: streamID, reason: .cancel)
        self.channel.pipeline.fireUserInboundEventTriggered(userEvent)
        XCTAssertTrue(closed)

        XCTAssertNoThrow(try self.channel.finish())
    }

    func testMultipleClosePromisesAreSatisfied() throws {
        let frameReceiver = FrameWriteRecorder()
        let channelPromise: EventLoopPromise<Channel> = self.channel.eventLoop.makePromise()
        let multiplexer = HTTP2StreamMultiplexer(mode: .server, channel: self.channel) { (channel, _) in
            channelPromise.succeed(channel)
            return channel.eventLoop.makeSucceededFuture(())
        }
        XCTAssertNoThrow(try self.channel.pipeline.addHandler(frameReceiver).wait())
        XCTAssertNoThrow(try self.channel.pipeline.addHandler(multiplexer).wait())


        XCTAssertNoThrow(try self.channel.connect(to: SocketAddress(unixDomainSocketPath: "/whatever"), promise: nil))

        // Let's send a headers frame to open the stream.
        let streamID = HTTP2StreamID(1)
        let frame = HTTP2Frame(streamID: streamID, payload: .headers(.init(headers: HPACKHeaders())))
        XCTAssertNoThrow(try self.channel.writeInbound(frame))

        // The channel should now be active.
        let childChannel = try channelPromise.futureResult.wait()
        XCTAssertTrue(childChannel.isActive)

        // Now we close it several times. This triggers one RST_STREAM frame. The channel will not be closed at this time.
        var firstClosed = false
        var secondClosed = false
        var thirdClosed = false
        childChannel.close().whenComplete { _ in
            XCTAssertFalse(firstClosed)
            XCTAssertFalse(secondClosed)
            XCTAssertFalse(thirdClosed)
            firstClosed = true
        }
        childChannel.close().whenComplete { _ in
            XCTAssertTrue(firstClosed)
            XCTAssertFalse(secondClosed)
            XCTAssertFalse(thirdClosed)
            secondClosed = true
        }
        childChannel.close().whenComplete { _ in
            XCTAssertTrue(firstClosed)
            XCTAssertTrue(secondClosed)
            XCTAssertFalse(thirdClosed)
            thirdClosed = true
        }
        XCTAssertEqual(frameReceiver.flushedWrites.count, 1)
        frameReceiver.flushedWrites[0].assertRstStreamFrame(streamID: streamID, errorCode: .cancel)
        XCTAssertFalse(thirdClosed)

        // Now send the stream closed event. This will satisfy the close promise.
        let userEvent = StreamClosedEvent(streamID: streamID, reason: .cancel)
        self.channel.pipeline.fireUserInboundEventTriggered(userEvent)
        XCTAssertTrue(thirdClosed)

        XCTAssertNoThrow(try self.channel.finish())
    }

    func testClosePromiseFailsWithError() throws {
        let frameReceiver = FrameWriteRecorder()
        let channelPromise: EventLoopPromise<Channel> = self.channel.eventLoop.makePromise()
        let multiplexer = HTTP2StreamMultiplexer(mode: .server, channel: self.channel) { (channel, _) in
            channelPromise.succeed(channel)
            return channel.eventLoop.makeSucceededFuture(())
        }
        XCTAssertNoThrow(try self.channel.pipeline.addHandler(frameReceiver).wait())
        XCTAssertNoThrow(try self.channel.pipeline.addHandler(multiplexer).wait())

        XCTAssertNoThrow(try self.channel.connect(to: SocketAddress(unixDomainSocketPath: "/whatever"), promise: nil))

        // Let's send a headers frame to open the stream.
        let streamID = HTTP2StreamID(1)
        let frame = HTTP2Frame(streamID: streamID, payload: .headers(.init(headers: HPACKHeaders())))
        XCTAssertNoThrow(try self.channel.writeInbound(frame))

        // The channel should now be active.
        let childChannel = try channelPromise.futureResult.wait()
        XCTAssertTrue(childChannel.isActive)

        // Now we close it. This triggers a RST_STREAM frame. The channel will not be closed at this time.
        var closeError: Error? = nil
        childChannel.close().whenFailure { closeError = $0 }
        XCTAssertEqual(frameReceiver.flushedWrites.count, 1)
        frameReceiver.flushedWrites[0].assertRstStreamFrame(streamID: streamID, errorCode: .cancel)
        XCTAssertNil(closeError)

        // Now send the stream closed event. This will fail the close promise.
        let userEvent = StreamClosedEvent(streamID: streamID, reason: .cancel)
        self.channel.pipeline.fireUserInboundEventTriggered(userEvent)
        XCTAssertEqual(closeError as? NIOHTTP2Errors.StreamClosed, NIOHTTP2Errors.StreamClosed(streamID: streamID, errorCode: .cancel))

        XCTAssertNoThrow(try self.channel.finish())
    }

    func testFramesAreNotDeliveredUntilStreamIsSetUp() throws {
        let channelPromise: EventLoopPromise<Channel> = self.channel.eventLoop.makePromise()
        let setupCompletePromise: EventLoopPromise<Void> = self.channel.eventLoop.makePromise()
        let multiplexer = HTTP2StreamMultiplexer(mode: .server, channel: self.channel) { (channel, _) in
            channelPromise.succeed(channel)
            return channel.pipeline.addHandler(InboundFrameRecorder()).flatMap {
                setupCompletePromise.futureResult
            }
        }
        XCTAssertNoThrow(try self.channel.pipeline.addHandler(multiplexer).wait())


        XCTAssertNoThrow(try self.channel.connect(to: SocketAddress(unixDomainSocketPath: "/whatever"), promise: nil))

        // Let's send a headers frame to open the stream.
        let streamID = HTTP2StreamID(1)
        let frame = HTTP2Frame(streamID: streamID, payload: .headers(.init(headers: HPACKHeaders())))
        XCTAssertNoThrow(try self.channel.writeInbound(frame))

        // The channel should now be available, but no frames should have been received on either the parent or child channel.
        let childChannel = try channelPromise.futureResult.wait()
        let frameRecorder = try childChannel.pipeline.context(handlerType: InboundFrameRecorder.self).wait().handler as! InboundFrameRecorder
        self.channel.assertNoFramesReceived()
        XCTAssertEqual(frameRecorder.receivedFrames.count, 0)

        // Send a few data frames for this stream, which should also not go through.
        var buffer = self.channel.allocator.buffer(capacity: 12)
        buffer.writeStaticString("Hello, world!")
        let dataFrame = HTTP2Frame(streamID: streamID, payload: .data(.init(data: .byteBuffer(buffer))))
        for _ in 0..<5 {
            XCTAssertNoThrow(try self.channel.writeInbound(dataFrame))
        }
        self.channel.assertNoFramesReceived()
        XCTAssertEqual(frameRecorder.receivedFrames.count, 0)

        // Use a PING frame to check that the channel is still functioning.
        let ping = HTTP2Frame(streamID: .rootStream, payload: .ping(HTTP2PingData(withInteger: 5), ack: false))
        XCTAssertNoThrow(try self.channel.writeInbound(ping))
        try self.channel.assertReceivedFrame().assertPingFrameMatches(this: ping)
        self.channel.assertNoFramesReceived()
        XCTAssertEqual(frameRecorder.receivedFrames.count, 0)

        // Ok, complete the setup promise. This should trigger all the frames to be delivered.
        setupCompletePromise.succeed(())
        self.channel.assertNoFramesReceived()
        XCTAssertEqual(frameRecorder.receivedFrames.count, 6)
        frameRecorder.receivedFrames[0].assertHeadersFrameMatches(this: frame)
        for idx in 1...5 {
            frameRecorder.receivedFrames[idx].assertDataFrameMatches(this: dataFrame)
        }

        XCTAssertNoThrow(try self.channel.finish())
    }

    func testFramesAreNotDeliveredIfSetUpFails() throws {
        let writeRecorder = FrameWriteRecorder()
        let channelPromise: EventLoopPromise<Channel> = self.channel.eventLoop.makePromise()
        let setupCompletePromise: EventLoopPromise<Void> = self.channel.eventLoop.makePromise()
        let multiplexer = HTTP2StreamMultiplexer(mode: .server, channel: self.channel) { (channel, _) in
            channelPromise.succeed(channel)
            return channel.pipeline.addHandler(InboundFrameRecorder()).flatMap {
                setupCompletePromise.futureResult
            }
        }
        XCTAssertNoThrow(try self.channel.pipeline.addHandler(writeRecorder).wait())
        XCTAssertNoThrow(try self.channel.pipeline.addHandler(multiplexer).wait())

        // Let's send a headers frame to open the stream, along with some DATA frames.
        let streamID = HTTP2StreamID(1)
        let frame = HTTP2Frame(streamID: streamID, payload: .headers(.init(headers: HPACKHeaders())))
        XCTAssertNoThrow(try self.channel.writeInbound(frame))

        var buffer = self.channel.allocator.buffer(capacity: 12)
        buffer.writeStaticString("Hello, world!")
        let dataFrame = HTTP2Frame(streamID: streamID, payload: .data(.init(data: .byteBuffer(buffer))))
        for _ in 0..<5 {
            XCTAssertNoThrow(try self.channel.writeInbound(dataFrame))
        }

        // The channel should now be available, but no frames should have been received on either the parent or child channel.
        let childChannel = try channelPromise.futureResult.wait()
        let frameRecorder = try childChannel.pipeline.context(handlerType: InboundFrameRecorder.self).wait().handler as! InboundFrameRecorder
        self.channel.assertNoFramesReceived()
        XCTAssertEqual(frameRecorder.receivedFrames.count, 0)

        // Ok, fail the setup promise. This should deliver a RST_STREAM frame, but not yet close the channel.
        // The channel should, however, be inactive.
        var channelClosed = false
        childChannel.closeFuture.whenComplete { _ in channelClosed = true }
        XCTAssertEqual(writeRecorder.flushedWrites.count, 0)
        XCTAssertFalse(channelClosed)

        setupCompletePromise.fail(MyError())
        self.channel.assertNoFramesReceived()
        XCTAssertEqual(frameRecorder.receivedFrames.count, 0)
        XCTAssertFalse(childChannel.isActive)
        XCTAssertEqual(writeRecorder.flushedWrites.count, 1)
        writeRecorder.flushedWrites[0].assertRstStreamFrame(streamID: streamID, errorCode: .cancel)

        // Even delivering a new DATA frame should do nothing.
        XCTAssertNoThrow(try self.channel.writeInbound(dataFrame))
        XCTAssertEqual(frameRecorder.receivedFrames.count, 0)

        // Now sending the stream closed event should complete the closure. All frames should be dropped. No new writes.
        let userEvent = StreamClosedEvent(streamID: streamID, reason: .cancel)
        self.channel.pipeline.fireUserInboundEventTriggered(userEvent)

        XCTAssertEqual(frameRecorder.receivedFrames.count, 0)
        XCTAssertFalse(childChannel.isActive)
        XCTAssertEqual(writeRecorder.flushedWrites.count, 1)
        XCTAssertFalse(channelClosed)

        (childChannel.eventLoop as! EmbeddedEventLoop).run()
        XCTAssertTrue(channelClosed)

        XCTAssertNoThrow(try self.channel.finish())
    }

    func testFlushingOneChannelDoesntFlushThemAll() throws {
        let writeTracker = FrameWriteRecorder()
        var channels: [Channel] = []
        let multiplexer = HTTP2StreamMultiplexer(mode: .server, channel: self.channel) { (channel, _) in
            channels.append(channel)
            return channel.eventLoop.makeSucceededFuture(())
        }
        XCTAssertNoThrow(try self.channel.pipeline.addHandler(writeTracker).wait())
        XCTAssertNoThrow(try self.channel.pipeline.addHandler(multiplexer).wait())

        XCTAssertNoThrow(try self.channel.connect(to: SocketAddress(unixDomainSocketPath: "/whatever"), promise: nil))

        // Let's open two streams.
        let firstStreamID = HTTP2StreamID(1)
        let secondStreamID = HTTP2StreamID(3)
        for streamID in [firstStreamID, secondStreamID] {
            let frame = HTTP2Frame(streamID: streamID, payload: .headers(.init(headers: HPACKHeaders(), endStream: true)))
            XCTAssertNoThrow(try self.channel.writeInbound(frame))
        }
        XCTAssertEqual(channels.count, 2)

        // We will now write a headers frame to each channel. Neither frame should be written to the connection. To verify this
        // we will flush the parent channel.
        for (idx, streamID) in [firstStreamID, secondStreamID].enumerated() {
            let frame = HTTP2Frame(streamID: streamID, payload: .headers(.init(headers: HPACKHeaders())))
            channels[idx].write(frame, promise: nil)
        }
        self.channel.flush()
        XCTAssertEqual(writeTracker.flushedWrites.count, 0)

        // Now we're going to flush only the first child channel. This should cause one flushed write.
        channels[0].flush()
        XCTAssertEqual(writeTracker.flushedWrites.count, 1)

        // Now the other.
        channels[1].flush()
        XCTAssertEqual(writeTracker.flushedWrites.count, 2)

        XCTAssertNoThrow(try self.channel.finish())
    }

    func testUnflushedWritesFailOnClose() throws {
        var childChannel: Channel? = nil
        let multiplexer = HTTP2StreamMultiplexer(mode: .server, channel: self.channel) { (channel, _) in
            childChannel = channel
            return channel.eventLoop.makeSucceededFuture(())
        }
        XCTAssertNoThrow(try self.channel.pipeline.addHandler(multiplexer).wait())

        // Let's open a stream.
        let streamID = HTTP2StreamID(1)
        let frame = HTTP2Frame(streamID: streamID, payload: .headers(.init(headers: HPACKHeaders(), endStream: true)))
        XCTAssertNoThrow(try self.channel.writeInbound(frame))
        XCTAssertNotNil(channel)

        // We will now write a headers frame to the channel, but don't flush it.
        var writeError: Error? = nil
        let responseFrame = HTTP2Frame(streamID: streamID, payload: .headers(.init(headers: HPACKHeaders())))
        childChannel!.write(responseFrame).whenFailure {
            writeError = $0
        }
        XCTAssertNil(writeError)

        // Now we're going to deliver a normal close to the stream.
        let userEvent = StreamClosedEvent(streamID: streamID, reason: nil)
        self.channel.pipeline.fireUserInboundEventTriggered(userEvent)
        XCTAssertEqual(writeError as? ChannelError, ChannelError.eof)

        XCTAssertNoThrow(try self.channel.finish())
    }

    func testUnflushedWritesFailOnError() throws {
        var childChannel: Channel? = nil
        let multiplexer = HTTP2StreamMultiplexer(mode: .server, channel: self.channel) { (channel, _) in
            childChannel = channel
            return channel.eventLoop.makeSucceededFuture(())
        }
        XCTAssertNoThrow(try self.channel.pipeline.addHandler(multiplexer).wait())

        // Let's open a stream.
        let streamID = HTTP2StreamID(1)
        let frame = HTTP2Frame(streamID: streamID, payload: .headers(.init(headers: HPACKHeaders(), endStream: true)))
        XCTAssertNoThrow(try self.channel.writeInbound(frame))
        XCTAssertNotNil(channel)

        // We will now write a headers frame to the channel, but don't flush it.
        var writeError: Error? = nil
        let responseFrame = HTTP2Frame(streamID: streamID, payload: .headers(.init(headers: HPACKHeaders())))
        childChannel!.write(responseFrame).whenFailure {
            writeError = $0
        }
        XCTAssertNil(writeError)

        // Now we're going to deliver a normal close to the stream.
        let userEvent = StreamClosedEvent(streamID: streamID, reason: .cancel)
        self.channel.pipeline.fireUserInboundEventTriggered(userEvent)
        XCTAssertEqual(writeError as? NIOHTTP2Errors.StreamClosed, NIOHTTP2Errors.StreamClosed(streamID: streamID, errorCode: .cancel))

        XCTAssertNoThrow(try self.channel.finish())
    }

    func testWritesFailOnClosedStreamChannels() throws {
        var childChannel: Channel? = nil
        let multiplexer = HTTP2StreamMultiplexer(mode: .server, channel: self.channel) { (channel, _) in
            childChannel = channel
            return channel.eventLoop.makeSucceededFuture(())
        }
        XCTAssertNoThrow(try self.channel.pipeline.addHandler(multiplexer).wait())

        // Let's open a stream.
        let streamID = HTTP2StreamID(1)
        let frame = HTTP2Frame(streamID: streamID, payload: .headers(.init(headers: HPACKHeaders(), endStream: true)))
        XCTAssertNoThrow(try self.channel.writeInbound(frame))
        XCTAssertNotNil(channel)

        // Now let's close it.
        let userEvent = StreamClosedEvent(streamID: streamID, reason: nil)
        self.channel.pipeline.fireUserInboundEventTriggered(userEvent)

        // We will now write a headers frame to the channel. This should fail immediately.
        var writeError: Error? = nil
        let responseFrame = HTTP2Frame(streamID: streamID, payload: .headers(.init(headers: HPACKHeaders())))
        childChannel!.write(responseFrame).whenFailure {
            writeError = $0
        }
        XCTAssertEqual(writeError as? ChannelError, ChannelError.ioOnClosedChannel)

        XCTAssertNoThrow(try self.channel.finish())
    }

    func testReadPullsInAllFrames() throws {
        var childChannel: Channel? = nil
        let frameRecorder = InboundFrameRecorder()
        let multiplexer = HTTP2StreamMultiplexer(mode: .server, channel: self.channel) { (channel, _) -> EventLoopFuture<Void> in
            childChannel = channel

            // We're going to disable autoRead on this channel.
            return channel.getOption(ChannelOptions.autoRead).map {
                XCTAssertTrue($0)
            }.flatMap {
                channel.setOption(ChannelOptions.autoRead, value: false)
            }.flatMap {
                channel.getOption(ChannelOptions.autoRead)
            }.map {
                XCTAssertFalse($0)
            }.flatMap {
                channel.pipeline.addHandler(frameRecorder)
            }
        }
        XCTAssertNoThrow(try self.channel.pipeline.addHandler(multiplexer).wait())


        XCTAssertNoThrow(try self.channel.connect(to: SocketAddress(unixDomainSocketPath: "/whatever"), promise: nil))

        // Let's open a stream.
        let streamID = HTTP2StreamID(1)
        let frame = HTTP2Frame(streamID: streamID, payload: .headers(.init(headers: HPACKHeaders())))
        XCTAssertNoThrow(try self.channel.writeInbound(frame))
        XCTAssertNotNil(channel)

        // Now we're going to deliver 5 data frames for this stream.
        var buffer = self.channel.allocator.buffer(capacity: 12)
        buffer.writeStaticString("Hello, world!")
        for _ in 0..<5 {
            let dataFrame = HTTP2Frame(streamID: streamID, payload: .data(.init(data: .byteBuffer(buffer))))
            XCTAssertNoThrow(try self.channel.writeInbound(dataFrame))
        }

        // These frames should not have been delivered.
        XCTAssertEqual(frameRecorder.receivedFrames.count, 0)

        // We'll call read() on the child channel.
        childChannel!.read()

        // All frames should now have been delivered.
        XCTAssertEqual(frameRecorder.receivedFrames.count, 6)
        frameRecorder.receivedFrames[0].assertFrameMatches(this: frame)
        for idx in 1...5 {
            frameRecorder.receivedFrames[idx].assertDataFrame(endStream: false, streamID: 1, payload: buffer)
        }

        XCTAssertNoThrow(try self.channel.finish())
    }

    func testReadIsPerChannel() throws {
        let firstStreamID = HTTP2StreamID(1)
        let secondStreamID = HTTP2StreamID(3)
        var frameRecorders: [HTTP2StreamID: InboundFrameRecorder] = [:]

        let multiplexer = HTTP2StreamMultiplexer(mode: .server, channel: self.channel) { (channel, streamID) -> EventLoopFuture<Void> in
            let recorder = InboundFrameRecorder()
            frameRecorders[streamID] = recorder

            // Disable autoRead on the first channel.
            return channel.setOption(ChannelOptions.autoRead, value: streamID != firstStreamID).flatMap {
                return channel.pipeline.addHandler(recorder)
            }
        }
        XCTAssertNoThrow(try self.channel.pipeline.addHandler(multiplexer).wait())

        XCTAssertNoThrow(try self.channel.connect(to: SocketAddress(unixDomainSocketPath: "/whatever"), promise: nil))

        // Let's open two streams.
        for streamID in [firstStreamID, secondStreamID] {
            let frame = HTTP2Frame(streamID: streamID, payload: .headers(.init(headers: HPACKHeaders())))
            XCTAssertNoThrow(try self.channel.writeInbound(frame))
        }
        XCTAssertEqual(frameRecorders.count, 2)

        // Stream 1 should not have received a frame, stream 3 should.
        XCTAssertEqual(frameRecorders[firstStreamID]!.receivedFrames.count, 0)
        XCTAssertEqual(frameRecorders[secondStreamID]!.receivedFrames.count, 1)

        // Deliver a DATA frame to each stream, which should also have gone into stream 3 but not stream 1.
        var buffer = self.channel.allocator.buffer(capacity: 12)
        buffer.writeStaticString("Hello, world!")
        for streamID in [firstStreamID, secondStreamID] {
            let frame = HTTP2Frame(streamID: streamID, payload: .data(.init(data: .byteBuffer(buffer))))
            XCTAssertNoThrow(try self.channel.writeInbound(frame))
        }

        // Stream 1 should not have received a frame, stream 3 should.
        XCTAssertEqual(frameRecorders[firstStreamID]!.receivedFrames.count, 0)
        XCTAssertEqual(frameRecorders[secondStreamID]!.receivedFrames.count, 2)

        XCTAssertNoThrow(try self.channel.finish())
    }

    func testReadWillCauseAutomaticFrameDelivery() throws {
        var childChannel: Channel? = nil
        let frameRecorder = InboundFrameRecorder()
        let multiplexer = HTTP2StreamMultiplexer(mode: .server, channel: self.channel) { (channel, _) -> EventLoopFuture<Void> in
            childChannel = channel

            // We're going to disable autoRead on this channel.
            return channel.setOption(ChannelOptions.autoRead, value: false).flatMap {
                channel.pipeline.addHandler(frameRecorder)
            }
        }
        XCTAssertNoThrow(try self.channel.pipeline.addHandler(multiplexer).wait())

        XCTAssertNoThrow(try self.channel.connect(to: SocketAddress(unixDomainSocketPath: "/whatever"), promise: nil))

        // Let's open a stream.
        let streamID = HTTP2StreamID(1)
        let frame = HTTP2Frame(streamID: streamID, payload: .headers(.init(headers: HPACKHeaders())))
        XCTAssertNoThrow(try self.channel.writeInbound(frame))
        XCTAssertNotNil(channel)

        // This stream should have seen no frames.
        XCTAssertEqual(frameRecorder.receivedFrames.count, 0)

        // Call read, the header frame will come through.
        childChannel!.read()
        XCTAssertEqual(frameRecorder.receivedFrames.count, 1)

        // Call read again, nothing happens.
        childChannel!.read()
        XCTAssertEqual(frameRecorder.receivedFrames.count, 1)

        // Now deliver a data frame.
        var buffer = self.channel.allocator.buffer(capacity: 12)
        buffer.writeStaticString("Hello, world!")
        let dataFrame = HTTP2Frame(streamID: streamID, payload: .data(.init(data: .byteBuffer(buffer))))
        XCTAssertNoThrow(try self.channel.writeInbound(dataFrame))

        // This frame should have been immediately delivered.
        XCTAssertEqual(frameRecorder.receivedFrames.count, 2)

        // Delivering another data frame does nothing.
        XCTAssertNoThrow(try self.channel.writeInbound(dataFrame))
        XCTAssertEqual(frameRecorder.receivedFrames.count, 2)

        XCTAssertNoThrow(try self.channel.finish())
    }

    func testReadWithNoPendingDataCausesReadOnParentChannel() throws {
        var childChannel: Channel? = nil
        let readCounter = ReadCounter()
        let frameRecorder = InboundFrameRecorder()
        let multiplexer = HTTP2StreamMultiplexer(mode: .server, channel: self.channel) { (channel, _) -> EventLoopFuture<Void> in
            childChannel = channel

            // We're going to disable autoRead on this channel.
            return channel.setOption(ChannelOptions.autoRead, value: false).flatMap {
                channel.pipeline.addHandler(frameRecorder)
            }
        }
        XCTAssertNoThrow(try self.channel.pipeline.addHandler(readCounter).wait())
        XCTAssertNoThrow(try self.channel.pipeline.addHandler(multiplexer).wait())

        XCTAssertNoThrow(try self.channel.connect(to: SocketAddress(unixDomainSocketPath: "/whatever"), promise: nil))

        // Let's open a stream.
        let streamID = HTTP2StreamID(1)
        let frame = HTTP2Frame(streamID: streamID, payload: .headers(.init(headers: HPACKHeaders())))
        XCTAssertNoThrow(try self.channel.writeInbound(frame))
        XCTAssertNotNil(channel)

        // This stream should have seen no frames.
        XCTAssertEqual(frameRecorder.receivedFrames.count, 0)

        // There should be no calls to read.
        XCTAssertEqual(readCounter.readCount, 0)

        // Call read, the header frame will come through. No calls to read on the parent stream.
        childChannel!.read()
        XCTAssertEqual(frameRecorder.receivedFrames.count, 1)
        XCTAssertEqual(readCounter.readCount, 0)

        // Call read again, read is called on the parent stream. No frames delivered.
        childChannel!.read()
        XCTAssertEqual(frameRecorder.receivedFrames.count, 1)
        XCTAssertEqual(readCounter.readCount, 1)

        // Now deliver a data frame.
        var buffer = self.channel.allocator.buffer(capacity: 12)
        buffer.writeStaticString("Hello, world!")
        let dataFrame = HTTP2Frame(streamID: streamID, payload: .data(.init(data: .byteBuffer(buffer))))
        XCTAssertNoThrow(try self.channel.writeInbound(dataFrame))

        // This frame should have been immediately delivered. No extra call to read.
        XCTAssertEqual(frameRecorder.receivedFrames.count, 2)
        XCTAssertEqual(readCounter.readCount, 1)

        // Another call to read issues a read to the parent stream.
        childChannel!.read()
        XCTAssertEqual(frameRecorder.receivedFrames.count, 2)
        XCTAssertEqual(readCounter.readCount, 2)

        // Another call to read, this time does not issue a read to the parent stream.
        childChannel!.read()
        XCTAssertEqual(frameRecorder.receivedFrames.count, 2)
        XCTAssertEqual(readCounter.readCount, 2)

        // Delivering two more frames does not cause another call to read, and only one frame
        // is delivered.
        XCTAssertNoThrow(try self.channel.writeInbound(dataFrame))
        XCTAssertNoThrow(try self.channel.writeInbound(dataFrame))
        XCTAssertEqual(frameRecorder.receivedFrames.count, 3)
        XCTAssertEqual(readCounter.readCount, 2)

        XCTAssertNoThrow(try self.channel.finish())
    }

    func testHandlersAreRemovedOnClosure() throws {
        var handlerRemoved = false
        let handlerRemovedPromise: EventLoopPromise<Void> = self.channel.eventLoop.makePromise()
        handlerRemovedPromise.futureResult.whenComplete { _ in handlerRemoved = true }

        let multiplexer = HTTP2StreamMultiplexer(mode: .server, channel: self.channel) { (channel, _) in
            return channel.pipeline.addHandler(HandlerRemovedHandler(removedPromise: handlerRemovedPromise))
        }
        XCTAssertNoThrow(try self.channel.pipeline.addHandler(multiplexer).wait())

        // Let's open a stream.
        let streamID = HTTP2StreamID(1)
        let frame = HTTP2Frame(streamID: streamID, payload: .headers(.init(headers: HPACKHeaders(), endStream: true)))
        XCTAssertNoThrow(try self.channel.writeInbound(frame))

        // No handlerRemoved so far.
        XCTAssertFalse(handlerRemoved)

        // Now we send the channel a clean exit.
        let event = StreamClosedEvent(streamID: streamID, reason: nil)
        self.channel.pipeline.fireUserInboundEventTriggered(event)
        XCTAssertFalse(handlerRemoved)

        // The handlers will only be removed after we spin the loop.
        (self.channel.eventLoop as! EmbeddedEventLoop).run()
        XCTAssertTrue(handlerRemoved)

        XCTAssertNoThrow(try self.channel.finish())
    }

    func testHandlersAreRemovedOnClosureWithError() throws {
        var handlerRemoved = false
        let handlerRemovedPromise: EventLoopPromise<Void> = self.channel.eventLoop.makePromise()
        handlerRemovedPromise.futureResult.whenComplete { _ in handlerRemoved = true }

        let multiplexer = HTTP2StreamMultiplexer(mode: .server, channel: self.channel) { (channel, _) in
            return channel.pipeline.addHandler(HandlerRemovedHandler(removedPromise: handlerRemovedPromise))
        }
        XCTAssertNoThrow(try self.channel.pipeline.addHandler(multiplexer).wait())

        // Let's open a stream.
        let streamID = HTTP2StreamID(1)
        let frame = HTTP2Frame(streamID: streamID, payload: .headers(.init(headers: HPACKHeaders(), endStream: true)))
        XCTAssertNoThrow(try self.channel.writeInbound(frame))

        // No handlerRemoved so far.
        XCTAssertFalse(handlerRemoved)

        // Now we send the channel a clean exit.
        let event = StreamClosedEvent(streamID: streamID, reason: .cancel)
        self.channel.pipeline.fireUserInboundEventTriggered(event)
        XCTAssertFalse(handlerRemoved)

        // The handlers will only be removed after we spin the loop.
        (self.channel.eventLoop as! EmbeddedEventLoop).run()
        XCTAssertTrue(handlerRemoved)

        XCTAssertNoThrow(try self.channel.finish())
    }

    func testCreatingOutboundChannel() throws {
        let configurePromise: EventLoopPromise<Void> = self.channel.eventLoop.makePromise()
        var createdChannelCount = 0
        var configuredChannelCount = 0
        var streamIDs = Array<HTTP2StreamID>()
        let multiplexer = HTTP2StreamMultiplexer(mode: .server, channel: self.channel) { (_, _) in
            XCTFail("Must not be called")
            return self.channel.eventLoop.makeFailedFuture(MyError())
        }
        XCTAssertNoThrow(try self.channel.pipeline.addHandler(multiplexer).wait())

        for _ in 0..<3 {
            let channelPromise: EventLoopPromise<Channel> = self.channel.eventLoop.makePromise()
            multiplexer.createStreamChannel(promise: channelPromise) { (channel, streamID) in
                createdChannelCount += 1
                streamIDs.append(streamID)
                return configurePromise.futureResult
            }
            channelPromise.futureResult.whenSuccess { _ in
                configuredChannelCount += 1
            }
        }

        XCTAssertEqual(createdChannelCount, 0)
        XCTAssertEqual(configuredChannelCount, 0)
        XCTAssertEqual(streamIDs.count, 0)

        (self.channel.eventLoop as! EmbeddedEventLoop).run()
        XCTAssertEqual(createdChannelCount, 3)
        XCTAssertEqual(configuredChannelCount, 0)
        XCTAssertEqual(streamIDs, [2, 4, 6].map { HTTP2StreamID($0) })

        configurePromise.succeed(())
        XCTAssertEqual(createdChannelCount, 3)
        XCTAssertEqual(configuredChannelCount, 3)
        XCTAssertEqual(streamIDs, [2, 4, 6].map { HTTP2StreamID($0) })

        XCTAssertNoThrow(try self.channel.finish())
    }

    func testCreatingOutboundChannelClient() throws {
        let configurePromise: EventLoopPromise<Void> = self.channel.eventLoop.makePromise()
        var createdChannelCount = 0
        var configuredChannelCount = 0
        var streamIDs = Array<HTTP2StreamID>()
        let multiplexer = HTTP2StreamMultiplexer(mode: .client, channel: self.channel) { (_, _) in
            XCTFail("Must not be called")
            return self.channel.eventLoop.makeFailedFuture(MyError())
        }
        XCTAssertNoThrow(try self.channel.pipeline.addHandler(multiplexer).wait())

        for _ in 0..<3 {
            let channelPromise: EventLoopPromise<Channel> = self.channel.eventLoop.makePromise()
            multiplexer.createStreamChannel(promise: channelPromise) { (channel, streamID) in
                createdChannelCount += 1
                streamIDs.append(streamID)
                return configurePromise.futureResult
            }
            channelPromise.futureResult.whenSuccess { _ in
                configuredChannelCount += 1
            }
        }

        XCTAssertEqual(createdChannelCount, 0)
        XCTAssertEqual(configuredChannelCount, 0)
        XCTAssertEqual(streamIDs.count, 0)

        (self.channel.eventLoop as! EmbeddedEventLoop).run()
        XCTAssertEqual(createdChannelCount, 3)
        XCTAssertEqual(configuredChannelCount, 0)
        XCTAssertEqual(streamIDs, [1, 3, 5].map { HTTP2StreamID($0) })

        configurePromise.succeed(())
        XCTAssertEqual(createdChannelCount, 3)
        XCTAssertEqual(configuredChannelCount, 3)
        XCTAssertEqual(streamIDs, [1, 3, 5].map { HTTP2StreamID($0) })

        XCTAssertNoThrow(try self.channel.finish())
    }

    func testWritesOnCreatedChannelAreDelayed() throws {
        let configurePromise: EventLoopPromise<Void> = self.channel.eventLoop.makePromise()
        let writeRecorder = FrameWriteRecorder()
        var childChannel: Channel? = nil
        var childStreamID: HTTP2StreamID? = nil

        XCTAssertNoThrow(try self.channel.connect(to: SocketAddress(unixDomainSocketPath: "/whatever"), promise: nil))

        let multiplexer = HTTP2StreamMultiplexer(mode: .server, channel: self.channel) { (_, _) in
            XCTFail("Must not be called")
            return self.channel.eventLoop.makeFailedFuture(MyError())
        }
        XCTAssertNoThrow(try self.channel.pipeline.addHandler(writeRecorder).wait())
        XCTAssertNoThrow(try self.channel.pipeline.addHandler(multiplexer).wait())
        multiplexer.createStreamChannel(promise: nil) { (channel, streamID) in
            childChannel = channel
            childStreamID = streamID
            return configurePromise.futureResult
        }
        (self.channel.eventLoop as! EmbeddedEventLoop).run()
        XCTAssertNotNil(childChannel)
        XCTAssertNotNil(childStreamID)

        childChannel!.writeAndFlush(HTTP2Frame(streamID: childStreamID!, payload: .headers(.init(headers: HPACKHeaders()))), promise: nil)
        XCTAssertEqual(writeRecorder.flushedWrites.count, 0)

        configurePromise.succeed(())
        (self.channel.eventLoop as! EmbeddedEventLoop).run()
        XCTAssertEqual(writeRecorder.flushedWrites.count, 1)

        XCTAssertNoThrow(try self.channel.finish())
    }

    func testWritesAreCancelledOnFailingInitializer() throws {
        let configurePromise: EventLoopPromise<Void> = self.channel.eventLoop.makePromise()
        var childChannel: Channel? = nil
        var childStreamID: HTTP2StreamID? = nil

        let multiplexer = HTTP2StreamMultiplexer(mode: .server, channel: self.channel) { (_, _) in
            XCTFail("Must not be called")
            return self.channel.eventLoop.makeFailedFuture(MyError())
        }
        XCTAssertNoThrow(try self.channel.pipeline.addHandler(multiplexer).wait())
        multiplexer.createStreamChannel(promise: nil) { (channel, streamID) in
            childChannel = channel
            childStreamID = streamID
            return configurePromise.futureResult
        }
        (self.channel.eventLoop as! EmbeddedEventLoop).run()

        var writeError: Error? = nil
        childChannel!.writeAndFlush(HTTP2Frame(streamID: childStreamID!, payload: .headers(.init(headers: HPACKHeaders())))).whenFailure { writeError = $0 }
        XCTAssertNil(writeError)

        configurePromise.fail(MyError())
        XCTAssertNotNil(writeError)
        XCTAssertTrue(writeError is MyError)

        XCTAssertNoThrow(try self.channel.finish())
    }

    func testFailingInitializerDoesNotWrite() throws {
        let configurePromise: EventLoopPromise<Void> = self.channel.eventLoop.makePromise()
        let writeRecorder = FrameWriteRecorder()

        let multiplexer = HTTP2StreamMultiplexer(mode: .server, channel: self.channel) { (_, _) in
            XCTFail("Must not be called")
            return self.channel.eventLoop.makeFailedFuture(MyError())
        }
        XCTAssertNoThrow(try self.channel.pipeline.addHandler(writeRecorder).wait())
        XCTAssertNoThrow(try self.channel.pipeline.addHandler(multiplexer).wait())
        multiplexer.createStreamChannel(promise: nil) { (channel, streamID) in
            return configurePromise.futureResult
        }
        (self.channel.eventLoop as! EmbeddedEventLoop).run()

        configurePromise.fail(MyError())
        XCTAssertEqual(writeRecorder.flushedWrites.count, 0)

        XCTAssertNoThrow(try self.channel.finish())
    }

    func testCreatedChildChannelDoesNotActivateEarly() throws {
        var activated = false

        let activePromise: EventLoopPromise<Void> = self.channel.eventLoop.makePromise()
        let activeRecorder = ActiveHandler(activatedPromise: activePromise)
        activePromise.futureResult.map {
            activated = true
        }.whenFailure { (_: Error) in
            XCTFail("Activation promise must not fail")
        }

        let multiplexer = HTTP2StreamMultiplexer(mode: .server, channel: self.channel) { (_, _) in
            XCTFail("Must not be called")
            return self.channel.eventLoop.makeFailedFuture(MyError())
        }
        XCTAssertNoThrow(try self.channel.pipeline.addHandler(multiplexer).wait())
        multiplexer.createStreamChannel(promise: nil) { (channel, streamID) in
            return channel.pipeline.addHandler(activeRecorder)
        }
        (self.channel.eventLoop as! EmbeddedEventLoop).run()
        XCTAssertFalse(activated)

        XCTAssertNoThrow(try self.channel.connect(to: SocketAddress(unixDomainSocketPath: "/whatever"), promise: nil))

        XCTAssertTrue(activated)

        XCTAssertNoThrow(try self.channel.finish())
    }

    func testCreatedChildChannelActivatesIfParentIsActive() throws {
        var activated = false

        let activePromise: EventLoopPromise<Void> = self.channel.eventLoop.makePromise()
        let activeRecorder = ActiveHandler(activatedPromise: activePromise)
        activePromise.futureResult.map {
            activated = true
        }.whenFailure { (_: Error) in
            XCTFail("Activation promise must not fail")
        }

        let multiplexer = HTTP2StreamMultiplexer(mode: .server, channel: self.channel) { (_, _) in
            XCTFail("Must not be called")
            return self.channel.eventLoop.makeFailedFuture(MyError())
        }
        XCTAssertNoThrow(try self.channel.pipeline.addHandler(multiplexer).wait())

        XCTAssertNoThrow(try self.channel.connect(to: SocketAddress(ipAddress: "127.0.0.1", port: 8765)).wait())
        XCTAssertFalse(activated)

        multiplexer.createStreamChannel(promise: nil) { (channel, streamID) in
            return channel.pipeline.addHandler(activeRecorder)
        }
        (self.channel.eventLoop as! EmbeddedEventLoop).run()
        XCTAssertTrue(activated)

        XCTAssertNoThrow(try self.channel.finish())
    }

    func testInitiatedChildChannelActivates() throws {
        XCTAssertNoThrow(try self.channel.connect(to: SocketAddress(unixDomainSocketPath: "/whatever"), promise: nil))

        var activated = false

        let activePromise: EventLoopPromise<Void> = self.channel.eventLoop.makePromise()
        let activeRecorder = ActiveHandler(activatedPromise: activePromise)
        activePromise.futureResult.map {
            activated = true
        }.whenFailure { (_: Error) in
            XCTFail("Activation promise must not fail")
        }

        let multiplexer = HTTP2StreamMultiplexer(mode: .server, channel: self.channel) { (channel, _) in
            return channel.pipeline.addHandler(activeRecorder)
        }
        XCTAssertNoThrow(try self.channel.pipeline.addHandler(multiplexer).wait())
        self.channel.pipeline.fireChannelActive()

        // Open a new stream.
        XCTAssertFalse(activated)
        let streamID = HTTP2StreamID(1)
        let frame = HTTP2Frame(streamID: streamID, payload: .headers(.init(headers: HPACKHeaders())))
        XCTAssertNoThrow(try self.channel.writeInbound(frame))
        XCTAssertTrue(activated)

        XCTAssertNoThrow(try self.channel.finish())
    }
}
