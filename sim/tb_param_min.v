`timescale 1ns/1ps
module tb_param_min;
    reg [23:0] in;
    reg [3:0] b = 4'd10, c = 4'd10;
    wire [23:0] out;
    param_apply u(.rgb_in(in), .bright(b), .contrast(c), .rgb_out(out));
    initial begin
        in = 24'h383870;
        #1; $display("[m] in=%06h out=%06h gain=%0d off=%0d", in, out, u.gain, u.off);
        in = 24'hFFFFFF; #1; $display("[m] white out=%06h", out);
        in = 24'h000000; #1; $display("[m] black out=%06h", out);
        $finish;
    end
endmodule
