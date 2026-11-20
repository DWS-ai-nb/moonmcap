///|
test "cancellation inside an attachment source stops the stream writer" {
  let out = @buffer.Buffer::Buffer()
  let writer = @moonmcap.new_stream_writer(
    @moonmcap.new_write_sink(bytes => out.write_bytes(bytes[:])),
  )
  let mut calls = 0
  let source = @moonmcap.new_read_source(70000UL, (_, length) => {
    calls += 1
    writer.cancel()
    Bytes::make(length, 7)
  })
  try
    writer.add_attachment_from(
      source, "cancelled.bin", "application/octet-stream",
    )
  catch {
    @moonmcap.Invalid(_) => ()
  } noraise {
    _ => fail("cancellation during source callback must interrupt the transfer")
  }
  assert_eq(calls, 1)
  assert_eq(writer.progress().state, @moonmcap.WriterCancelled)
  try ignore(writer.finish()) catch {
    @moonmcap.Invalid(_) => ()
  } noraise {
    _ => fail("cancelled writer cannot publish a completed footer")
  }
}

///|
test "attachment copy supports CRC absent and empty payload" {
  let log = {
    ..@moonmcap.empty_log(),
    attachments: [
      {
        log_time: 0UL,
        create_time: 0UL,
        name: "empty",
        media_type: "application/octet-stream",
        data: b"",
      },
    ],
  }
  let recording = @moonmcap.write_log(log, checksums=false)
  let reader = @moonmcap.open_reader(@moonmcap.memory_source(recording))
  let found = []
  reader.visit_attachments(item => {
    found.push(item)
    true
  })
  assert_eq(found.length(), 1)
  let written = @buffer.Buffer::Buffer()
  assert_false(
    found[0].copy_to(
      @moonmcap.new_write_sink(bytes => written.write_bytes(bytes[:])),
    ),
  )
  assert_eq(written.length(), 0)
}

///|
test "short-read attachment sources preserve exact payload and CRC" {
  let output = @buffer.Buffer::Buffer()
  let writer = @moonmcap.new_stream_writer(
    @moonmcap.new_write_sink(bytes => output.write_bytes(bytes[:])),
  )
  let payload = Bytes::makei(131079, index => (index % 251).to_byte())
  let mut input_reads = 0
  let source = @moonmcap.new_read_source(payload.length().to_uint64(), (
    offset,
    length,
  ) => {
    input_reads += 1
    let start = offset.to_int()
    payload[start:start + length.min(97)].to_owned()
  })
  writer.add_attachment_from(
    source, "short-read.bin", "application/octet-stream",
  )
  ignore(writer.finish())
  assert_true(input_reads > 1000)
  let reader = @moonmcap.open_reader(@moonmcap.memory_source(output.to_bytes()))
  let found = []
  reader.visit_attachments(item => {
    found.push(item)
    true
  })
  let extracted = @buffer.Buffer::Buffer()
  assert_true(
    found[0].copy_to(
      @moonmcap.new_write_sink(bytes => extracted.write_bytes(bytes[:])),
    ),
  )
  assert_eq(extracted.to_bytes(), payload)
}

///|
test "attachment payload IO failures poison the writer and preserve input error" {
  let writer = @moonmcap.new_stream_writer(
    @moonmcap.new_write_sink(fn(_) { () }),
  )
  let source = @moonmcap.new_read_source(131072UL, (offset, length) => {
    if offset != 0UL {
      raise @moonmcap.io_error("source device disconnected")
    }
    Bytes::make(length, 3)
  })
  try
    writer.add_attachment_from(source, "failed.bin", "application/octet-stream")
  catch {
    @moonmcap.Invalid(reason) =>
      assert_true(reason.contains("source device disconnected"))
  } noraise {
    _ => fail("source failure should propagate")
  }
  assert_eq(writer.progress().state, @moonmcap.WriterFailed)
}

///|
test "sink cancellation while flushing pending messages stops further writes" {
  let cancel = [false]
  let owner : Array[@moonmcap.StreamWriter] = []
  let mut calls = 0
  let writer = @moonmcap.new_stream_writer(
    @moonmcap.new_write_sink(bytes => {
      ignore(bytes)
      calls += 1
      if cancel[0] {
        owner[0].cancel()
      }
    }),
  )
  owner.push(writer)
  writer.add_channel({
    id: 1,
    schema_id: 0,
    topic: "/test",
    message_encoding: "raw",
    metadata: [],
  })
  writer.append({
    channel_id: 1,
    sequence: 0U,
    log_time: 1UL,
    publish_time: 1UL,
    data: b"pending",
  })
  let before = calls
  cancel[0] = true
  try
    writer.add_attachment_from(
      @moonmcap.memory_source(b"payload"),
      "cancelled",
      "raw",
    )
  catch {
    @moonmcap.Invalid(_) => ()
  } noraise {
    _ =>
      fail(
        "sink cancellation while flushing must interrupt attachment creation",
      )
  }
  assert_eq(calls, before + 1)
  assert_eq(writer.progress().state, @moonmcap.WriterCancelled)
}

///|
fn audit_copy_cancellation(
  at_checksum : Bool,
  cancel_session : Bool,
) -> Unit raise {
  let recording = @moonmcap.write_log({
    ..@moonmcap.empty_log(),
    attachments: [
      {
        log_time: 0UL,
        create_time: 0UL,
        name: "cancel-test",
        media_type: "raw",
        data: b"payload",
      },
    ],
  })
  let sessions : Array[@moonmcap.AttachmentCopy] = []
  let mut checksum_at = 0UL
  let mut armed = false
  let mut cancelled = false
  let source = @moonmcap.new_read_source(recording.length().to_uint64(), (
    offset,
    length,
  ) => {
    let target = if at_checksum { checksum_at } else { checksum_at - 7UL }
    if armed && offset == target {
      if cancel_session {
        sessions[0].cancel()
      } else {
        cancelled = true
      }
    }
    recording[offset.to_int():offset.to_int() + length].to_owned()
  })
  let reader = @moonmcap.open_reader(source)
  let attachments = []
  reader.visit_attachments(item => {
    attachments.push(item)
    true
  })
  let info = attachments[0].info()
  checksum_at = info.offset + info.length - 4UL
  let written = @buffer.Buffer::Buffer()
  let copy = attachments[0].start_copy(
    @moonmcap.new_write_sink(bytes => written.write_bytes(bytes[:])),
  )
  sessions.push(copy)
  armed = true
  try ignore(copy.step(cancelled=() => cancelled)) catch {
    @moonmcap.Invalid(reason) => assert_true(reason.contains("cancel"))
  } noraise {
    _ => fail("a cancellation during source I/O cannot complete extraction")
  }
  assert_false(copy.progress().complete)
  assert_false(copy.progress().crc_verified)
  assert_eq(written.length(), if at_checksum { 7 } else { 0 })
}

///|
test "copy cancellation during the last checksum read prevents completion" {
  audit_copy_cancellation(true, true)
}

///|
test "copy cancellation inside payload source precedes the next sink write" {
  audit_copy_cancellation(false, true)
}

///|
test "copy observes external cancellation after the last checksum read" {
  audit_copy_cancellation(true, false)
}
