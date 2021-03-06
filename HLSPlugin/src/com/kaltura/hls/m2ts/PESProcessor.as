package com.kaltura.hls.m2ts
{
    import flash.utils.ByteArray;
    import flash.net.ObjectEncoding;
    import flash.utils.ByteArray;
    import flash.utils.Endian;    
    import flash.utils.IDataInput;
    import flash.utils.IDataOutput;
    import com.hurlant.util.Hex;

    CONFIG::LOGGING
    {
        import org.osmf.logging.Logger;
        import org.osmf.logging.Log;
    }

    /**
     * Process packetized elementary streams and extract NALUs and other data.
     */
    public class PESProcessor
    {
        CONFIG::LOGGING
        {
            private static const logger:Logger = Log.getLogger("com.kaltura.hls.m2ts.PESProcessor");
        }

        public var types:Object = {};
        public var streams:Object = {};

        public var lastVideoNALU:NALU = null;

		public var lastID3NALU:NALU = null;
		public var lastID3Point:uint;
		
        public var transcoder:FLVTranscoder = new FLVTranscoder();

        public var headerSent:Boolean = false;

        public var pmtStreamId:int = -1;

        public var hasVideo:Boolean = false;

        protected var pendingBuffers:Vector.<Object> = new Vector.<Object>();
        protected var pendingLastConvertedIndex:int = 0;

        public var lastPTS:Number = NaN, lastDTS:Number = NaN;

        /**
         * Given a MPEG timestamp we've seen previously, determine if the new timestamp
         * has wrapped and correct it to follow the old timestamp.
         */
        public static function handleMpegTimestampWrap(newTime:Number, oldTime:Number):Number
        {
            while (!isNaN(oldTime) && (Math.abs(newTime - oldTime) > 4294967296))
                newTime += (oldTime < newTime) ? -8589934592 : 8589934592;

            return newTime;
        }

        public function logStreams():void
        {
            CONFIG::LOGGING
            {
                logger.debug("----- PES state -----");
                for(var k:* in streams)
                {
                    logger.debug("   " + k + " has " + streams[k].buffer.length + " bytes, type=" + types[k]);
                }                
            }
        }

        public function clear(clearAACConfig:Boolean = true):void
        {
            hasVideo = false;
            streams = {};
            lastVideoNALU = null;
            transcoder.clear(clearAACConfig);

            // Don't reset PTS/DTS reference. This implies the
            // total stream length is < ~27 hours or else you'll
            // get erroneous timecodes.
        }

        private function parseProgramAssociationTable(bytes:ByteArray, cursor:uint):Boolean
        {
            // Get the section length.
            var sectionLen:uint = ((bytes[cursor+2] & 0x03) << 8) | bytes[cursor+3];

            // Check the section length for a single PMT.
            CONFIG::LOGGING
            {
                if (sectionLen > 13)
                {
                    logger.debug("Saw multiple PMT entries in the PAT; blindly choosing first one.");
                }
            }

            // Grab the PMT ID.
            pmtStreamId = ((bytes[cursor+10] << 8) | bytes[cursor+11]) & 0x1FFF;

            CONFIG::LOGGING
            {
                logger.debug("Saw PMT ID of " + pmtStreamId);
            }

            return true;
        }

        private function parseProgramMapTable(bytes:ByteArray, cursor:uint, id3Callback:Function):Boolean
        {
            var sectionLength:uint;
            var sectionLimit:uint;
            var programInfoLength:uint;
            var type:uint;
            var pid:uint;
			var oldPosition:uint;
            var esInfoLength:uint;
            var seenPIDsByClass:Array;
            var mediaClass:int;

            var hasAudio:Boolean = false;

            // Set up types.
            types = [];
            seenPIDsByClass = [];
            seenPIDsByClass[MediaClass.VIDEO] = Infinity;
            seenPIDsByClass[MediaClass.AUDIO] = Infinity;
			seenPIDsByClass[MediaClass.ID3] = 0;
			
            // Process section length and limit.
            cursor++;
            
            sectionLength = ((bytes[cursor] & 0x0f) << 8) + bytes[cursor + 1];
            cursor += 2;

            if(sectionLength + cursor > bytes.length)
            {
                CONFIG::LOGGING
                {
                    logger.error("Not enough data to read. 1");                    
                }
                return false;
            }
            
            // Skip a few things we don't care about: program number, RSV, version, CNI, section, last_section, pcr_cid
            sectionLimit = cursor + sectionLength;          
            cursor += 7;
            
            // And get the program info length.
            programInfoLength = ((bytes[cursor] & 0x0f) << 8) + bytes[cursor + 1];
            cursor += 2;
            
            // If not enough data to proceed, bail.
            if(programInfoLength + cursor > bytes.length)
            {
                CONFIG::LOGGING
                {
                    logger.error("Not enough data to read. 2");
                }
                return false;
            }

            cursor += programInfoLength;
                        
            const CRC_SIZE:int = 4;
            while(cursor < sectionLimit - CRC_SIZE)
            {
                type = bytes[cursor++];
                pid = ((bytes[cursor] & 0x1f) << 8) + bytes[cursor + 1];
                cursor += 2;
                
                mediaClass = MediaClass.calculate(type);
                
                if(mediaClass == MediaClass.VIDEO)
                    hasVideo = true

                if(mediaClass == MediaClass.AUDIO)
                    hasAudio = true

                // For video & audio, select the lowest PID for each kind.
                if(mediaClass == MediaClass.OTHER
                 || pid < seenPIDsByClass[mediaClass]) 
                {
                    // Clear a higher PID if present.
                    if(mediaClass != MediaClass.OTHER
                     && seenPIDsByClass[mediaClass] < Infinity)
                        types[seenPIDsByClass[mediaClass]] = -1;
                    
                    types[pid] = type;
                    seenPIDsByClass[mediaClass] = pid;
                }
                
                // Check for ID3 tag content.
				oldPosition = bytes.position;
				var id3Offset:Number = indexOf(bytes,"ID3",cursor);
				if (id3Offset > 0)
                {
					lastID3Point = pid;
                    CONFIG::LOGGING
                    {
                        logger.debug("ID3 found at PID #" + pid + " offset=" + id3Offset + " lastDTS=" + lastDTS);
                    }
                    
                    // You can use this to parse the tag immediately but it will not have a valid
                    // DTS as PMT doesn't have DTS.
                    //bytes.position = id3Offset;
                    //id3Callback(bytes, lastDTS);
				}
				bytes.position = oldPosition;
				
				// Skip the esInfo data.
                esInfoLength = ((bytes[cursor] & 0x0f) << 8) + bytes[cursor + 1];
                cursor += 2;
                cursor += esInfoLength;
            }

            // Note that we've processed a PMT.
            headerSent = true;
            
            return true;
        }

		public function indexOf(bytes:ByteArray, search:String, startOffset:uint = 0):Number
		{
			if (bytes == null || bytes.length == 0) {
				throw new ArgumentError("bytes parameter should not be null or empty");
			}
							
			if (search == null || search.length == 0) {
				throw new ArgumentError("search parameter should not be null or empty");
			}
								
			// Fast return is the search pattern length is shorter than the bytes one
			if (bytes.length < startOffset + search.length) {
				return -1;
			}
						
			// Create the pattern
			var pattern:ByteArray = new ByteArray();
			pattern.writeUTFBytes(search);
						
			// Initialize loop variables
			var end:Boolean;
			var found:Boolean;
			var i:uint = startOffset;
			var j:uint = 0;
			var p:uint = pattern.length;
			var n:uint = bytes.length - p;
					
			// Repeat util end
			do {
				// Compare the current byte with the first one of the pattern
				if (bytes[i] == pattern[0]) {
					found = true;
					j = p;
								
					// Loop through every byte of the pattern
					while (--j) {
						if (bytes[i + j] != pattern[j]) {
								found = false;
							break;
						}
					}
										
					// Return the pattern position
					if (found) {
						return i;
					}
				}
			
				// Check if end is reach
				end = (++i > n);
			} while (!end);
						
			// Pattern not found
			return -1;
		}
		
		public function append(packet:PESPacket, id3Callback:Function):Boolean
        {
            //logger.debug("saw packet of " + packet.buffer.length);
            var b:ByteArray = packet.buffer;
            b.position = 0;

            if(b.length < 8)
            {
                CONFIG::LOGGING
                {
                    logger.error("Ignoring too short PES packet, length=" + b.length);                    
                }
                return true;
            }

            // Get the start code.
            var startCode:uint = b.readUnsignedInt();
            if((startCode & 0xFFFFFF00) != 0x00000100)
            {
                // It could be a program association table.
                if((startCode & 0xFFFFFF00) == 0x0000b000)
                {
                    parseProgramAssociationTable(b, 1);
                    return true;
                }

                // It could be the program map table.
                if((startCode & 0xFFFFFC00) == 0x0002b000)
                {
                    parseProgramMapTable(b, 1, id3Callback);
                    return true;
                }

                var tmp:ByteArray = new ByteArray();
                tmp.writeInt(startCode);
                CONFIG::LOGGING
                {
                    logger.error("ES prefix was wrong, expected 00:00:01:xx but got " + Hex.fromArray(tmp, true));
                }
                return true;
            }

            // Get the stream ID.
            var streamID:int = startCode & 0xFF;

            // Get the length.
            var packetLength:uint = b.readUnsignedShort();
            if(packetLength)
            {
                if(b.length < packetLength )
                {
                    CONFIG::LOGGING
                    {
                        logger.warn("WARNING: parsePESPacket - not enough bytes, expecting " + packetLength + ", but have " + b.length);
                    }
                    return false; // not enough bytes in packet
                }
            }
            
            if(b.length < 9)
            {
                CONFIG::LOGGING
                {
                    logger.warn("WARNING: parsePESPacket - too short to read header!");
                }
                return false;
            }

            // Read the rest of the header.
            var cursor:uint = 6;
            var dataAlignment:Boolean = (b[cursor] & 0x04) != 0;
            cursor++;
            
            var ptsDts:uint = (b[cursor] & 0xc0) >> 6;
            cursor++;
            
            var pesHeaderDataLength:uint = b[cursor];
            cursor++;

            //logger.debug(" PES align=" + dataAlignment + " ptsDts=" + ptsDts + " header=" + pesHeaderDataLength);

            var pts:Number = 0, dts:Number = 0;
            
            if(ptsDts & 0x02)
            {
                // has PTS at least
                if(cursor + 5 > b.length)
                    return true;
                
                pts  = b[cursor] & 0x0e;
                pts *= 128;
                pts += b[cursor + 1];
                pts *= 256;
                pts += b[cursor + 2] & 0xfe;
                pts *= 128;
                pts += b[cursor + 3];
                pts *= 256;
                pts += b[cursor + 4] & 0xfe;
                pts /= 2;
                
                if(ptsDts & 0x01)
                {
                    // DTS too!
                    if(cursor + 10 > b.length)
                        return true;
                    
                    dts  = b[cursor + 5] & 0x0e;
                    dts *= 128;
                    dts += b[cursor + 6];
                    dts *= 256;
                    dts += b[cursor + 7] & 0xfe;
                    dts *= 128;
                    dts += b[cursor + 8];
                    dts *= 256;
                    dts += b[cursor + 9] & 0xfe;
                    dts /= 2;
                }
                else
                {
                    //logger.debug("Filling in DTS")
                    dts = pts;
                }
            }

            // Condition PTS and DTS.
            pts = handleMpegTimestampWrap(pts, lastPTS);
            lastPTS = pts;

            dts = handleMpegTimestampWrap(dts, pts);
            lastDTS = dts;

            packet.pts = pts;
            packet.dts = dts;

            //logger.debug("   PTS=" + pts/90000 + " DTS=" + dts/90000);

            cursor += pesHeaderDataLength;
            
            if(cursor > b.length)
            {
                CONFIG::LOGGING
                {
                    logger.warn("WARNING: parsePESPacket - ran out of bytes");
                }
                return true;
            }
            
            if(types[packet.packetID] == undefined)
            {
                CONFIG::LOGGING
                {
                    logger.warn("WARNING: parsePESPacket - unknown type");
                }
                return true;
            }
            
            var pes:PESPacketStream;

            if(streams[packet.packetID] == undefined)
            {
                if(dts < 0.0)
                {
                    // This actually isn't a big deal if we are working with negative timestamps.
                    CONFIG::LOGGING
                    {
                        logger.warn("WARNING: parsePESPacket - invalid decode timestamp? DTS="  + dts);
                    }
                    dts += 0; // nop to avoid warnings when logging is off.
                }
                
                pes = new PESPacketStream();
                streams[packet.packetID] = pes;
            }
            else
            {
                pes = streams[packet.packetID];
            }
            
            if(headerSent == false)
            {
                CONFIG::LOGGING
                {
                    logger.warn("Skipping data that came before PMT");
                }
                return true;
            }

            // Note the type at this moment in time.
            packet.type = types[packet.packetID];
            packet.headerLength = cursor;

			if (lastID3Point == packet.packetID)
			{
                CONFIG::LOGGING
                {
                    logger.debug("Processing ID3 tag. PTS=" + pts);
                }
				id3Callback(b, pts/90000);
			}
            else if(MediaClass.calculate(types[packet.packetID]) == MediaClass.VIDEO)
            {
				// And process.
                var start:int = NALU.scan(b, cursor, true);
                if(start == -1 && lastVideoNALU)
                {
                    CONFIG::LOGGING
                    {
                        logger.debug("Stuff entire " + (b.length - cursor) + " bytes into previous NALU.");
                    }
                    lastVideoNALU.buffer.position = lastVideoNALU.buffer.length;
                    b.position = 0;
                    lastVideoNALU.buffer.writeBytes(b, cursor, b.length - cursor);
                    return true;

                }
                else if((start - cursor) > 0 && lastVideoNALU)
                {
                    // Shove into previous buffer.
                    CONFIG::LOGGING
                    {
                        logger.debug("Stuffing first " + (start - cursor) + " bytes into previous NALU.");
                    }
                    lastVideoNALU.buffer.position = lastVideoNALU.buffer.length;
                    b.position = 0;
                    lastVideoNALU.buffer.writeBytes(b, cursor, start - cursor);
                    cursor = start;
                }

                // If it's identical timestamps, accumulate it into the current unit and keep going.
                if(lastVideoNALU && pts == lastVideoNALU.pts && dts == lastVideoNALU.dts)
                {
                    CONFIG::LOGGING
                    {
                        logger.debug("Combining " + (start-cursor) + " bytes into previous NALU due to matching DTS/PTS.");
                    }
                    lastVideoNALU.buffer.position = lastVideoNALU.buffer.length;
                    b.position = 0;
                    lastVideoNALU.buffer.writeBytes(b, cursor, start - cursor);
                    cursor = start;                    
                }
                else
                {
                    // Submit previous data.
                    if(lastVideoNALU)
                    {
                        pendingBuffers.push(lastVideoNALU.clone());
                    }

                    // Update NALU state.
                    lastVideoNALU = new NALU();
                    lastVideoNALU.buffer = new ByteArray();
                    lastVideoNALU.pts = pts;
                    lastVideoNALU.dts = dts;
                    lastVideoNALU.type = packet.type;
                    lastVideoNALU.buffer.writeBytes(b, cursor);

                }
            }
            else if(types[packet.packetID] == 0x0F)
            {
                // It's an AAC stream.
                pendingBuffers.push(packet.clone());
            }
            else if(types[packet.packetID] == 0x03 || types[packet.packetID] == 0x04)
            {
                // It's an MP3 stream.
                pendingBuffers.push(packet.clone());
            }
            else
            {
                CONFIG::LOGGING
                {
                    logger.warn("Unknown packet ID type " + types[packet.packetID] + ", ignoring (A).");
                }
            }

            bufferPendingNalus();

            return true;
        }

        /**
         * To avoid transcoding all content on flush, we buffer it into FLV
         * tags as we go. However, they remain undelivered until we can gather
         * final SPS/PPS information. This method is responsible for
         * incrementally buffering in the FLV transcoder as we go.
         */
        public function bufferPendingNalus():void
        {
            // Iterate and buffer new NALUs.
            for(var i:int=pendingLastConvertedIndex; i<pendingBuffers.length; i++)
            {
                if(pendingBuffers[i] is NALU)
                {
                    transcoder.convert(pendingBuffers[i] as NALU);
                }
                else if(pendingBuffers[i] is PESPacket)
                {
                    var packet:PESPacket = pendingBuffers[i] as PESPacket;
                    if(packet.type == 0x0F)
                    {
                        // It's an AAC stream.
                        transcoder.convertAAC(packet);
                    }
                    else if(packet.type == 0x03 || packet.type == 0x04)
                    {
                        // It's an MP3 stream. Pass through directly.
                        transcoder.convertMP3(packet);
                    }
                    else
                    {
                        CONFIG::LOGGING
                        {
                            logger.warn("Unknown packet ID type " + packet.type + ", ignoring (B).");                            
                        }
                    }
                }
            }

            // Note the last item we converted so we can avoid duplicating work.
            pendingLastConvertedIndex = pendingBuffers.length;
        }

        public function processAllNalus():void
        {
            // Consume any unposted video NALUs.
            if(lastVideoNALU)
            {
                pendingBuffers.push(lastVideoNALU.clone());
                lastVideoNALU = null;
            }

            // First walk all the video NALUs and get the correct SPS/PPS
            if(pendingBuffers.length == 0)
                return;
            
            // Then emit SPS/PPS
            transcoder.emitSPSPPSUnbuffered();

            // Complete buffering and emit it all.
            bufferPendingNalus();
            transcoder.emitBufferedTags();

            // Don't forget to clear the pending list.
            pendingBuffers.length = 0;
            pendingLastConvertedIndex = 0;
        }
    }
}
