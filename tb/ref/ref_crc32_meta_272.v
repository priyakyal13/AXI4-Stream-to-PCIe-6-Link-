// REFERENCE: verbatim copy of the original bit-serial metadata CRC, module renamed _ref.
// IEEE CRC-32 over a 272-bit metadata field, bytes consumed low-to-high.
// Reflected polynomial 0xEDB88320, init/final XOR 0xFFFFFFFF.
// This CRC protects the TKEEP, TLAST, beat-valid and magic/version fields.
module crc32_meta_272_ref (
    input  [271:0] data,
    output reg [31:0] crc
);
    integer b, k;
    reg [31:0] c;
    reg [7:0] byte_value;
    always @* begin
        c = 32'hFFFFFFFF;
        for (b = 0; b < 34; b = b + 1) begin
            byte_value = data[b*8 +: 8];
            c = c ^ byte_value;
            for (k = 0; k < 8; k = k + 1) begin
                if (c[0]) c = (c >> 1) ^ 32'hEDB88320;
                else      c = c >> 1;
            end
        end
        crc = c ^ 32'hFFFFFFFF;
    end
endmodule
