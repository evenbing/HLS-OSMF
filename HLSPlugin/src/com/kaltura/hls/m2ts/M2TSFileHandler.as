package com.kaltura.hls.m2ts
{
	import com.kaltura.hls.HLSStreamingResource;
	import com.kaltura.hls.SubtitleTrait;
	import com.kaltura.hls.manifest.HLSManifestEncryptionKey;
	import com.kaltura.hls.muxing.AACParser;
	import com.kaltura.hls.subtitles.SubTitleParser;
	import com.kaltura.hls.subtitles.TextTrackCue;
	import com.kaltura.hls.HLSIndexHandler;
	
	import flash.utils.ByteArray;
	import flash.utils.IDataInput;
	import flash.utils.getTimer;
	
	import org.osmf.events.HTTPStreamingEvent;
	import org.osmf.net.httpstreaming.HTTPStreamingFileHandlerBase;
	import org.osmf.net.httpstreaming.flv.FLVTagAudio;

	/**
	 * Process M2TS data into FLV data and return it for rendering via OSMF video system.
	 */
	public class M2TSFileHandler extends HTTPStreamingFileHandlerBase
	{
		public var subtitleTrait:SubtitleTrait;
		public var key:HLSManifestEncryptionKey;
		public var segmentId:uint = 0;
		public var resource:HLSStreamingResource;
		public var segmentUri:String;
		public var isBestEffort:Boolean = false;
		
		private var _parser:TSPacketParser;
		private var _curTimeOffset:uint;
		private var _buffer:ByteArray;
		private var _fragReadBuffer:ByteArray;
		private var _encryptedDataBuffer:ByteArray;
		private var _timeOrigin:uint;
		private var _timeOriginNeeded:Boolean;
		private var _segmentBeginSeconds:Number;
		private var _segmentLastSeconds:Number;
		private var _firstSeekTime:Number;
		private var _lastContinuityToken:String;
		private var _extendedIndexHandler:IExtraIndexHandlerState;
		private var _lastFLVMessageTime:Number;
		private var _injectingSubtitles:Boolean = false;
		private var _lastInjectedSubtitleTime:Number = 0;
		
		private var _decryptionIV:ByteArray;
		
		public function M2TSFileHandler()
		{
			super();
			
			_encryptedDataBuffer = new ByteArray();

			_parser = new TSPacketParser();
			_parser.callback = handleFLVMessage;
			
			_timeOrigin = 0;
			_timeOriginNeeded = true;
			
			_segmentBeginSeconds = -1;
			_segmentLastSeconds = -1;
			
			_firstSeekTime = 0;
			
			_extendedIndexHandler = null;
			
			_lastContinuityToken = null;
		}

		public function get duration():Number
		{
			if(_segmentLastSeconds > _segmentBeginSeconds)
				return _segmentLastSeconds - _segmentBeginSeconds;
			return -1;
		}

		public function set extendedIndexHandler(handler:IExtraIndexHandlerState):void
		{
			_extendedIndexHandler = handler;
		}
		
		public function get extendedIndexHandler():IExtraIndexHandlerState
		{
			return _extendedIndexHandler;
		}
		
		public override function beginProcessFile(seek:Boolean, seekTime:Number):void
		{
			if(isBestEffort)
			{
				trace("Doing extra flush for best effort file handler");
				_parser.flush();
				_parser.clear();
			}

			// Decryption reset
			if ( key )
			{
				if ( key.iv ) _decryptionIV = key.retrieveStoredIV();
				else _decryptionIV = HLSManifestEncryptionKey.createIVFromID( segmentId );
			}
			
			var discontinuity:Boolean = false;
			
			if(_extendedIndexHandler)
			{
				var currentContinuityToken:String = _extendedIndexHandler.getCurrentContinuityToken();
				
				if(_lastContinuityToken != currentContinuityToken)
					discontinuity = true;
				_lastContinuityToken = currentContinuityToken;
			}
			
			if(seek)
			{
				_parser.clear();
				
				_timeOriginNeeded = true;
				
				if(_extendedIndexHandler)
					_firstSeekTime = _extendedIndexHandler.calculateFileOffsetForTime(seekTime) * 1000.0;
			}
			else if(discontinuity)
			{
				// Kick the converter state, but try to avoid upsetting the audio stream.
				_parser.clear(false);
				
				if(_segmentLastSeconds >= 0.0)
				{
					_timeOriginNeeded = true;
					if(_extendedIndexHandler)
						_firstSeekTime = _extendedIndexHandler.getCurrentSegmentOffset() * 1000.0;
					else
						_firstSeekTime = _segmentLastSeconds * 1000.0 + 30;
				}
			}
			else if(_extendedIndexHandler && _segmentLastSeconds >= 0.0)
			{
				var currentFileOffset:Number = _extendedIndexHandler.getCurrentSegmentOffset();
				var delta:Number = currentFileOffset - _segmentLastSeconds;

				// If it's a big jump, handle it.
				if(delta > 5.0)
				{
					_timeOriginNeeded = true;
					_firstSeekTime = currentFileOffset * 1000.0;
				}
			}
			
			_segmentBeginSeconds = -1;
			_segmentLastSeconds = -1;
			_lastInjectedSubtitleTime = -1;
		}
		
		public override function get inputBytesNeeded():Number
		{
			// Get TS packets!
			return 188;
		}

		public static var tmpBuffer:ByteArray = new ByteArray();

		private function basicProcessFileSegment(input:IDataInput, flush:Boolean):ByteArray
		{
			if ( key && !key.isLoaded )
			{
				input.readBytes( _encryptedDataBuffer, _encryptedDataBuffer.length );
				return null;
			}
			
			tmpBuffer.position = 0;
			tmpBuffer.length = 0;
			
			if ( _encryptedDataBuffer.length > 0 )
			{
				_encryptedDataBuffer.position = 0;
				_encryptedDataBuffer.readBytes( tmpBuffer );
				_encryptedDataBuffer.clear();
			}
			
			input.readBytes( tmpBuffer, tmpBuffer.length );
			
			if ( key )
			{
				var bytesToRead:uint = tmpBuffer.length;
				var leftoverBytes:uint = bytesToRead % 16;
				bytesToRead -= leftoverBytes;
				
				key.usePadding = false;
				
				if ( leftoverBytes > 0 )
				{
					// Place any bytes left over (not divisible by 16) into our encrypted buffer
					// to decrypt later, when we have more bytes
					tmpBuffer.position = bytesToRead;
					tmpBuffer.readBytes( _encryptedDataBuffer );
					tmpBuffer.length = bytesToRead;
				}
				else
				{
					// Attempt to unpad if our buffer is equally divisible by 16.
					// It could mean that we've reached the end of the file segment.
					 key.usePadding = true;
				}
				
				// Store our current IV so we can use it do decrypt
				var currentIV:ByteArray = _decryptionIV;
				
				// Set up the IV for our next set of bytes
				_decryptionIV = new ByteArray();
				tmpBuffer.position = bytesToRead - 16;
				tmpBuffer.readBytes( _decryptionIV );
				
				// Aaaaand...decrypt!
				key.decrypt( tmpBuffer, currentIV );
			}
			
			// If it's AAC, process it.
			if(AACParser.probe(tmpBuffer))
			{
				//trace("GOT AAC " + tmpBuffer.bytesAvailable);
				var aac:AACParser = new AACParser();
				aac.parse(tmpBuffer, _fragReadHandler);
				//trace("    - returned " + _fragReadBuffer.length + " bytes!");
				_fragReadBuffer.position = 0;

				if(isBestEffort && _fragReadBuffer.length > 0)
				{
					trace("Discarding AAC data from best effort.");
					_fragReadBuffer.length = 0;
				}

				return _fragReadBuffer;
			}
			
			var buffer:ByteArray = new ByteArray();
			_buffer = buffer;
			_parser.appendBytes(tmpBuffer);
			if ( flush ) _parser.flush();
			_buffer = null;
			buffer.position = 0;
			
			if(isBestEffort && buffer.length > 0)
			{
				trace("Discarding normal data from best effort.");
				buffer.length = 0;
			}

			return buffer;
		}
		
		private function _fragReadHandler(audioTags:Vector.<FLVTagAudio>, adif:ByteArray):void 
		{
			_fragReadBuffer = new ByteArray();
			var audioTag:FLVTagAudio = new FLVTagAudio();
			audioTag.soundFormat = FLVTagAudio.SOUND_FORMAT_AAC;
			audioTag.data = adif;
			audioTag.isAACSequenceHeader = true;
			audioTag.write(_fragReadBuffer);
			
			for(var i:int=0; i<audioTags.length; i++)
				audioTags[i].write(_fragReadBuffer);
		}

		public override function processFileSegment(input:IDataInput):ByteArray
		{
			return basicProcessFileSegment(input, false);
		}
		
		public override function endProcessFile(input:IDataInput):ByteArray
		{
			if ( key ) key.usePadding = true;
			
			var rv:ByteArray = basicProcessFileSegment(input, false);
			
			var elapsed:Number = _segmentLastSeconds - _segmentBeginSeconds;
			
			if(elapsed <= 0.0 && _extendedIndexHandler)
			{
				elapsed = _extendedIndexHandler.getTargetSegmentDuration(); // XXX fudge hack!
			}

			dispatchEvent(new HTTPStreamingEvent(HTTPStreamingEvent.FRAGMENT_DURATION, false, false, elapsed));
			
			return rv;
		}
		
		public override function flushFileSegment(input:IDataInput):ByteArray
		{
			return basicProcessFileSegment(input || new ByteArray(), true);
		}
				
		private function handleFLVMessage(timestamp:uint, message:ByteArray):void
		{
			var timestampSeconds:Number = timestamp / 1000.0;

			if(_segmentBeginSeconds < 0)
			{
				_segmentBeginSeconds = timestampSeconds;
				trace("Noting segment start time for " + segmentUri + " of " + timestampSeconds);
				HLSIndexHandler.startTimeWitnesses[segmentUri] = timestampSeconds;
			}

			if(timestampSeconds > _segmentLastSeconds)
				_segmentLastSeconds = timestampSeconds;

			if(isBestEffort)
				return;

			//trace("Got " + message.length + " bytes at " + timestampSeconds + " seconds");

			if(_timeOriginNeeded)
			{
				_timeOrigin = timestamp;
				_timeOriginNeeded = false;
			}
			
			if(timestamp < _timeOrigin)
				_timeOrigin = timestamp;
			
			// Encode the timestamp.
			message[6] = (timestamp      ) & 0xff;
			message[5] = (timestamp >>  8) & 0xff;
			message[4] = (timestamp >> 16) & 0xff;
			message[7] = (timestamp >> 24) & 0xff;

			var lastMsgTime:Number = _lastFLVMessageTime;
			_lastFLVMessageTime = timestampSeconds;
			
			// If timer was reset due to seek, reset last subtitle time
			if(timestampSeconds < _lastInjectedSubtitleTime)
			{
				trace("Bumping back on subtitle threshold.")
				_lastInjectedSubtitleTime = timestampSeconds;
			} 
			
			// Inject any subtitle tags between messages
			injectSubtitles( _lastInjectedSubtitleTime + 0.001, timestampSeconds );
			
			//trace( "MESSAGE RECEIVED " + timestampSeconds );
			
			_buffer.writeBytes(message);
		}

		protected var _lastCue:TextTrackCue = null;
		
		private function injectSubtitles( startTime:Number, endTime:Number ):void
		{
			//if(startTime > endTime) trace("***** BAD BEHAVIOR " + startTime + " " + endTime);

			//trace("Inject subtitles " + startTime + " " + endTime);

			// Early out if no subtitles, no time has elapsed or we are already injecting subtitles
			if ( !subtitleTrait || endTime - startTime <= 0 || _injectingSubtitles ) return;
			
			var subtitles:Vector.<SubTitleParser> = subtitleTrait.activeSubtitles;
			if ( !subtitles ) return;
			
			_injectingSubtitles = true;
			
			var subtitleCount:int = subtitles.length;
			for ( var i:int = 0; i < subtitleCount; i++ )
			{
				var subtitle:SubTitleParser = subtitles[ i ];
				if ( subtitle.startTime > endTime ) break;
				var cues:Vector.<TextTrackCue> = subtitle.textTrackCues;
				var cueCount:int = cues.length;
				
				var potentials:Vector.<TextTrackCue> = new Vector.<TextTrackCue>();

				for ( var j:int = 0; j < cueCount; j++ )
				{
					var cue:TextTrackCue = cues[ j ];
					if ( cue.startTime > endTime ) break;
					else if ( cue.startTime >= startTime )
					{
						potentials.push(cue);
					}
				}

				if(potentials.length > 0)
				{
					// TODO: Add support for trackid
					cue = potentials[potentials.length - 1];
					if(cue != _lastCue)
					{
						_parser.createAndSendCaptionMessage( cue.startTime, cue.buffer, subtitleTrait.language );
						_lastInjectedSubtitleTime = cue.startTime;
						_lastCue = cue;						
					}
				}
			}
			
			_injectingSubtitles = false;
		}
	}
}