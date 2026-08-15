package rv32_pkg;

	localparam int unsigned XLEN      	= 32;
	localparam int unsigned STRB_WIDTH 	= XLEN / 8;
	localparam int unsigned AXI4_LEN	= 32;

	typedef logic [STRB_WIDTH-1:0] strb_t;

	// ---------------------------------------------------------------
	// Memory request (master -> memoria)
	//
	// `valid` is high for one cycle when a new request is launched.
	// `we` = 1 indicates a write (wdata/wstrb meaningful); `we` = 0
	// is a read (only `addr` is meaningful on the request side; the
	// read data comes back through mem_rsp_t.rdata).
	// ---------------------------------------------------------------
	typedef struct packed {
		logic  valid;                                    // 1 = request launched this cycle
		logic  we;                                       // 1 = write, 0 = read
		logic [XLEN-1:0]        addr;                    // byte address
		logic [XLEN-1:0]        wdata;                   // write data (ignored if we=0)
		logic [STRB_WIDTH-1:0]	wstrb;                   // byte strobes; all-1 on a word store
	} mem_req_t;

	// ---------------------------------------------------------------
	// Memory response (memoria -> master), 1 ciclo dopo la request
	// ---------------------------------------------------------------
	typedef struct packed {
		logic  valid;   // 1 = rdata is valid this cycle
		logic [XLEN-1:0] rdata;
	} mem_rsp_t;

	// ---------------------------------------------------------------
	// Convenience: a "request handshake" predicate. The bridge that
	// turns imem_req_o into an actual bus transaction is expected to
	// consume the request when req_valid && req_ready (the ready side
	// is owned by the bridge, not by the producer stage).
	// ---------------------------------------------------------------
	function automatic logic req_handshake(input mem_req_t req, input logic ready);
		return req.valid && ready;
	endfunction

endpackage
