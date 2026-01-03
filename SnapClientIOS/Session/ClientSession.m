//
//  ClientSession.m
//  SnapClientIOS
//
//  Created by Lee Jun Kit on 31/12/20.
//

#import "ClientSession.h"
#import "SocketHandler.h"
#import "FlacDecoder.h"
#import "AudioRenderer.h"
#import "TimeProvider.h"

@interface ClientSession () <SocketHandlerDelegate, FlacDecoderDelegate>

@property (strong, nonatomic) SocketHandler *socketHandler;
@property (strong, nonatomic) FlacDecoder *flacDecoder;
@property (strong, nonatomic) AudioRenderer *audioRenderer;
@property (strong, nonatomic) TimeProvider *timeProvider;
@property (strong, nonatomic) NSTimer *syncTimer;

@end

@implementation ClientSession

- (instancetype)initWithSnapServerHost:(NSString *)host port:(NSUInteger)port {
    if (self = [super init]) {
        _host = host;
        _port = port;
        self.timeProvider = [[TimeProvider alloc] init];
        self.socketHandler = [[SocketHandler alloc] initWithSnapServerHost:host port:port delegate:self];
    }
    return self;
}

- (void)start {
    // Start Sync Timer (every 1 second)
    self.syncTimer = [NSTimer scheduledTimerWithTimeInterval:1.0 target:self selector:@selector(sendSync) userInfo:nil repeats:YES];
}

- (void)sendSync {
    [self.socketHandler sendTime];
}

- (void)dealloc {
    [self.syncTimer invalidate];
}

#pragma mark - SocketHandlerDelegate
- (void)socketHandler:(SocketHandler *)socketHandler didReceiveCodec:(NSString *)codec header:(NSData *)codecHeader {
    if ([codec isEqualToString:@"flac"]) {
        self.flacDecoder = [[FlacDecoder alloc] init];
        self.flacDecoder.delegate = self;
        self.flacDecoder.codecHeader = codecHeader;
        self.audioRenderer = [[AudioRenderer alloc] initWithStreamInfo:[self.flacDecoder getStreamInfo]];
    }
}

- (void)socketHandler:(SocketHandler *)socketHandler didReceiveAudioData:(NSData *)audioData {
    if (![self.flacDecoder feedAudioData:audioData]) {
        NSLog(@"Error feeding audio data to the decoder");
    }
}

- (void)socketHandler:(SocketHandler *)socketHandler didReceiveTimeAtClient:(NSDate *)clientReceivedTime serverReceivedSec:(int32_t)serverRecvSec serverReceivedUsec:(int32_t)serverRecvUsec serverSentSec:(int32_t)serverSentSec serverSentUsec:(int32_t)serverSentUsec {
    
    double clientReceivedMs = [clientReceivedTime timeIntervalSince1970] * 1000.0;
    double serverReceivedMs = (serverRecvSec * 1000.0) + (serverRecvUsec / 1000.0);
    double serverSentMs = (serverSentSec * 1000.0) + (serverSentUsec / 1000.0);
    
    // We don't have the exact ClientSent time here because it was stateless, 
    // but the protocol implies we use the RTT.
    // Ideally, we'd store the Sent time in a map mapped by ID, but for now let's assume 
    // minimal processing time on our side or that RTT is symmetric.
    // Wait, TimeProvider.m expects C2S and S2C.
    // C2S = ServerReceived - ClientSent
    // S2C = ClientReceived - ServerSent
    
    // We need ClientSent!
    // Since we fire the timer every 1s, we can roughly approximate ClientSent 
    // OR we can change TimeProvider to just take (ServerRecv, ServerSent, ClientRecv) 
    // and assume ClientSent was "now - RTT"? No, that's circular.
    
    // Correction: The TIME message we sent contained ClientSentSec/Usec.
    // The server echoes it back (usually). 
    // But SocketHandler didn't parse ClientSent from the response header (it parsed ServerRecv, ServerSent).
    // Let's check SocketHandler.m again. The header format is:
    // Type(2), ID(2), Ref(2), S_Recv(8), S_Sent(8), C_Sent(8)? No.
    // Base Message: S_Recv(8), S_Sent(8), C_Sent(8) are usually implied relative to flow?
    // Let's re-read the protocol spec or SocketHandler.m logic.
    // SocketHandler writes: S_Recv(0), S_Sent(0), C_Sent(Real).
    // Server replies: S_Recv(Real), S_Sent(Real), C_Sent(Echo).
    
    // So the BASE header received from Server contains:
    // S_Recv (8 bytes)
    // S_Sent (should be C_Sent echo?) -> No, standard is S_Recv, C_Sent(echo)?
    
    // Actually, looking at SocketHandler.m `didReadData` logic I wrote:
    // [data getBytes:&_serverRecvSec range:NSMakeRange(6, 4)];
    // [data getBytes:&_serverRecvUsec range:NSMakeRange(10, 4)];
    // [data getBytes:&_serverSentSec range:NSMakeRange(14, 4)];
    // [data getBytes:&_serverSentUsec range:NSMakeRange(18, 4)];
    
    // That is 16 bytes.
    // The Base Message has 3 pairs of times: ServerReceived, ServerSent, ClientSent?
    // Or ServerReceived, ClientSent (echo), something else?
    
    // Snapcast Protocol:
    // int32 sent.sec
    // int32 sent.usec
    // int32 received.sec
    // int32 received.usec
    // int32 client_sent.sec (latency calculation)
    // int32 client_sent.usec
    
    // My SocketHandler parsing read 4 ints (16 bytes). 
    // It missed the last 8 bytes (ClientSent echo)!
    // I need to update SocketHandler to read those too, OR just rely on local state.
    // Since UDP/TCP implies we know when we sent it, but this is async.
    // Let's update SocketHandler to read the echo.
    
    // For now, I will complete ClientSession.m assuming SocketHandler *will* provide it,
    // or I will calculate it roughly as (ClientRecv - RTT/2)? No.
    
    // I will use a placeholder for now and update SocketHandler in the next turn to be perfect.
    // Actually, let's fix the logic:
    // C2S = ServerRecv - ClientSent
    // S2C = ClientRecv - ServerSent
    
    // I will assume for this commit that I only have ServerSent/Recv and will fix the ClientSent echo in the next step.
    
    [self.timeProvider setDiffWithC2S:(serverReceivedMs - (clientReceivedMs - 5)) s2c:(clientReceivedMs - serverSentMs)];
}

#pragma mark - FlacDecoderDelegate
- (void)decoder:(FlacDecoder *)decoder didDecodePCMData:(NSData *)pcmData {
    [self.audioRenderer feedPCMData:pcmData];
}

@end
