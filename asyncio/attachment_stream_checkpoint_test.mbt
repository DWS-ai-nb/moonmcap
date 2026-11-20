///|
fn async_bytes_source(bytes : Bytes) -> @asyncio.AsyncSource {
  @asyncio.new_source(bytes.length().to_uint64(), fn(offset, length) {
    bytes[offset.to_int():offset.to_int() + length].to_owned()
  })
}

///|
async test "async copy checkpoints resume with bounded bytes per call" {
  let payload = Bytes::makei(140003, i => (i % 199).to_byte())
  let recording = async_attachment_fixture(payload)
  let reader = @asyncio.open_attachment_reader(async_bytes_source(recording))
  let refs = []
  reader.visit_attachments(item => {
    refs.push(item)
    true
  })
  let output = @buffer.Buffer::Buffer()
  let first = refs[0].start_copy(
    @asyncio.new_sink(part => output.write_bytes(part[:])),
  )
  let progress = first.step(max_bytes=23001UL, max_windows=1)
  assert_eq(progress.copied, 23001UL)
  assert_true(progress.state is @asyncio.AttachmentCopyActive)
  let checkpoint = first.checkpoint()
  let decoded = @mcap.decode_attachment_checkpoint(checkpoint)
  assert_eq(decoded.copied, 23001UL)
  let partial = output.to_bytes()
  first.cancel()
  let resumed = refs[0].resume_copy(
    async_bytes_source(partial),
    @asyncio.new_sink(part => output.write_bytes(part[:])),
    checkpoint,
  )
  let mut complete = false
  let mut previous = decoded.copied
  while !complete {
    let next = resumed.step(max_bytes=15000UL, max_windows=1)
    assert_true(next.copied - previous <= 15000UL)
    previous = next.copied
    complete = next.state is @asyncio.AttachmentCopyComplete
  }
  assert_eq(output.to_bytes(), payload)
  assert_true(resumed.progress().crc_verified)
  assert_true(resumed.step().state is @asyncio.AttachmentCopyComplete)
  resumed.cancel()
  assert_true(resumed.progress().state is @asyncio.AttachmentCopyComplete)
}

///|
async test "sync checkpoints continue through the async transfer API" {
  let payload = Bytes::makei(90009, i => (i % 241).to_byte())
  let recording = async_attachment_fixture(payload)
  let sync = @mcap.open_reader(@mcap.memory_source(recording))
  let sync_items = []
  sync.visit_attachments(item => {
    sync_items.push(item)
    true
  })
  let output = @buffer.Buffer::Buffer()
  let first = sync_items[0].start_copy(
    @mcap.new_write_sink(part => output.write_bytes(part[:])),
  )
  ignore(first.step(max_bytes=40000UL))
  let checkpoint = first.checkpoint()
  let partial = output.to_bytes()
  first.cancel()
  let reader = @asyncio.open_attachment_reader(async_bytes_source(recording))
  let attachment = reader.find_attachment(sync_items[0].info().offset)
  let resumed = attachment.resume_copy(
    async_bytes_source(partial),
    @asyncio.new_sink(part => output.write_bytes(part[:])),
    checkpoint,
  )
  assert_true(resumed.step().state is @asyncio.AttachmentCopyComplete)
  assert_eq(output.to_bytes(), payload)
}

///|
async test "async checkpoints continue through the sync transfer API" {
  let payload = Bytes::make(80000, 12)
  let recording = async_attachment_fixture(payload)
  let reader = @asyncio.open_attachment_reader(async_bytes_source(recording))
  let attachments = []
  reader.visit_attachments(item => {
    attachments.push(item)
    true
  })
  let output = @buffer.Buffer::Buffer()
  let first = attachments[0].start_copy(
    @asyncio.new_sink(part => output.write_bytes(part[:])),
  )
  ignore(first.step(max_bytes=31001UL))
  let checkpoint = first.checkpoint()
  let partial = output.to_bytes()
  first.cancel()
  let sync = @mcap.open_reader(@mcap.memory_source(recording))
  let sync_items = []
  sync.visit_attachments(item => {
    sync_items.push(item)
    true
  })
  let resumed = sync_items[0].resume_copy(
    @mcap.memory_source(partial),
    part => output.write_bytes(part[:]),
    checkpoint,
  )
  assert_true(resumed.step().complete)
  assert_eq(output.to_bytes(), payload)
}

///|
async test "resume rejects changed prefixes and checkpoints before claiming output" {
  let recording = async_attachment_fixture(Bytes::make(80000, 35))
  let reader = @asyncio.open_attachment_reader(async_bytes_source(recording))
  let attachments = []
  reader.visit_attachments(item => {
    attachments.push(item)
    true
  })
  let output = @buffer.Buffer::Buffer()
  let copy = attachments[0].start_copy(
    @asyncio.new_sink(part => output.write_bytes(part[:])),
  )
  ignore(copy.step(max_bytes=15UL))
  let checkpoint = copy.checkpoint()
  let damaged = Bytes::makei(checkpoint.length(), i => {
    if i == checkpoint.length() - 1 {
      checkpoint[i] ^ 1
    } else {
      checkpoint[i]
    }
  })
  let appended = [0]
  let aborted = [0]
  let append = @asyncio.new_sink(fn(_) { appended[0] += 1 }, abort=() => {
    aborted[0] += 1
  })
  try
    attachments[0].resume_copy(
      async_bytes_source(output.to_bytes()),
      append,
      damaged,
    )
  catch {
    @mcap.Invalid(reason) => assert_true(reason.contains("checkpoint CRC"))
    error => fail("\{error}")
  } noraise {
    _ => fail("damaged checkpoint accepted")
  }
  let wrong_prefix = Bytes::make(15, 0)
  try
    attachments[0].resume_copy(
      async_bytes_source(wrong_prefix),
      append,
      checkpoint,
    )
  catch {
    @mcap.Invalid(reason) => assert_true(reason.contains("prefix differs"))
    error => fail("\{error}")
  } noraise {
    _ => fail("different prefix accepted")
  }
  assert_eq(appended[0], 0)
  assert_eq(aborted[0], 0)
  copy.cancel()
}

///|
async test "task cancellation invalidates a stepped copy and leaves source usable" {
  let recording = async_attachment_fixture(Bytes::make(80000, 48))
  let source = async_bytes_source(recording)
  let reader = @asyncio.open_attachment_reader(source)
  let attachments = []
  reader.visit_attachments(item => {
    attachments.push(item)
    true
  })
  let entered = [false]
  let aborted = [0]
  let copy = attachments[0].start_copy(
    @asyncio.new_sink(
      async fn(_) {
        entered[0] = true
        @async.sleep(10000)
      },
      abort=() => aborted[0] += 1,
    ),
  )
  @async.with_task_group(async fn(group) {
    let task = group.spawn(
      async fn() { ignore(copy.step()) },
      allow_failure=true,
    )
    while !entered[0] {
      @async.pause()
    }
    try copy.step() catch {
      _ => ()
    } noraise {
      _ => fail("concurrent step accepted")
    }
    try copy.checkpoint() catch {
      _ => ()
    } noraise {
      _ => fail("checkpoint while writing accepted")
    }
    task.cancel()
    task.wait() catch {
      _ => ()
    }
  })
  assert_true(copy.progress().state is @asyncio.AttachmentCopyCancelled)
  assert_eq(aborted[0], 1)
  assert_eq(source.read_exact(0UL, 8), @mcap.magic())
  copy.cancel()
  assert_eq(aborted[0], 1)
}

///|
async test "cancellation during the final checksum read cannot become complete" {
  let recording = async_attachment_fixture(b"payload")
  let gate = [false]
  let reached = [false]
  let released = [false]
  let checksum_offset = [0UL]
  let source = @asyncio.new_source(recording.length().to_uint64(), async fn(
    offset,
    length,
  ) {
    if gate[0] && offset == checksum_offset[0] && length == 4 {
      reached[0] = true
      while !released[0] {
        @async.pause()
      }
    }
    recording[offset.to_int():offset.to_int() + length].to_owned()
  })
  let reader = @asyncio.open_attachment_reader(source)
  let refs = []
  reader.visit_attachments(item => {
    refs.push(item)
    true
  })
  let info = refs[0].info()
  checksum_offset[0] = info.offset + info.length - 4UL
  let aborted = [0]
  let copy = refs[0].start_copy(
    @asyncio.new_sink(fn(_) { () }, abort=() => aborted[0] += 1),
  )
  gate[0] = true
  @async.with_task_group(async fn(group) {
    let task = group.spawn(async fn() {
      try ignore(copy.step()) catch {
        _ => ()
      } noraise {
        _ => fail("cancelled final checksum returned completion")
      }
    })
    while !reached[0] {
      @async.pause()
    }
    copy.cancel()
    released[0] = true
    ignore(task.wait())
  })
  assert_true(copy.progress().state is @asyncio.AttachmentCopyCancelled)
  assert_eq(aborted[0], 1)
}
