package rv32_pkg;

	localparam int unsigned XLEN      	= 32;
	localparam int unsigned STRB_WIDTH 	= XLEN / 8;
	localparam int unsigned AXI4_LEN	= 32;

	typedef logic [STRB_WIDTH-1:0] strb_t;

	// ---------------------------------------------------------------
	// Native memory interface — split per DIREZIONE (stile AXI):
	// ogni bundle e' una sola direzione, cosi' e' legale come packed
	// struct passata come singola porta. I canali (request / read
	// response) sono mischiati dentro ciascun bundle.
	//
	// Handshake richiesta (launch): req.wvalid && rsp.wready.
	// Handshake read response:       rsp.rvalid && req.rready.
	// ---------------------------------------------------------------

	// master -> bridge  (tutti gli OUTPUT del master)
	typedef struct packed {
		logic                  wvalid;   // request valid (launch)
		logic                  we;       // 1 = write, 0 = read
		logic [XLEN-1:0]       addr;     // byte address
		logic [XLEN-1:0]       wdata;    // write data (ignored if we=0)
		logic [STRB_WIDTH-1:0] wstrb;    // byte strobes; all-1 on a word store
		logic                  rready;   // master ready to accept read data
	} mem_req_t;

	// bridge -> master  (tutti gli INPUT del master)
	typedef struct packed {
		logic            wready;   // bridge accepts the request (= idle)
		logic            rvalid;   // read data valid this cycle
		logic [XLEN-1:0] rdata;    // read data
		// TODO(LSU): add bvalid (write-ack, bridge->master). The fetch
		// is read-only so it is not needed yet; the peri bridge is tied
		// off and no write is ever launched today.
	} mem_rsp_t;

	// ---------------------------------------------------------------
	// Convenience: request-launch predicate (req.wvalid && rsp.wready).
	// ---------------------------------------------------------------
	function automatic logic req_handshake(input mem_req_t req, input mem_rsp_t rsp);
		return req.wvalid && rsp.wready;
	endfunction

endpackage