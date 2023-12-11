module top_level(
    input wire clk_100mhz,
    input wire [15:0] sw,
    input wire [7:0] pmoda, // Input wires from the mics (data)
    output logic [7:0] pmodb, // Output wires to the mics (clocks)
    input wire [3:0] btn,
    output logic [6:0] ss0_c, ss1_c,
    output logic [3:0] ss0_an, ss1_an,
    output logic [2:0] rgb0, rgb1, //rgb led
    output logic spkl, spkr, //speaker outputs
    output logic [15:0] led, // led outputs
    output logic uart_txd, // if we want to use Manta
    input wire uart_rxd
);

  assign led = sw;
  logic sys_rst;
  assign sys_rst = btn[0];
  assign rgb1 = 0;
  assign rgb0 = 0;

  logic [7:0] DELAY_AMOUNT;
  assign DELAY_AMOUNT = {sw[15:10], 2'b0};

  // ### CLOCK SETUP

  // 98.3MHz
  logic audio_clk;
  audio_clk_wiz macw (.clk_in(clk_100mhz), .clk_out(audio_clk)); 

  // This triggers at 24kHz for general audio
  logic audio_trigger;
  logic [11:0] audio_trigger_counter;
  always_ff @(posedge audio_clk) begin
      audio_trigger_counter <= audio_trigger_counter + 1;
  end
  assign audio_trigger = (audio_trigger_counter == 0);


  // ### MIC INPUT

  // Mic 1: bclk - i2s_clk - pmodb[3]; dout - mic_1_data - pmoda[3]; lrcl_clk - pmodb[2], sel - grounded
  // Mic 2: bclk - i2s_clk - pmodb[7]; dout - mic_2_data - pmoda[7]; lrcl_clk - pmodb[6], sel - grounded

  logic mic_1_data, mic_2_data;
  logic i2s_clk_1, i2s_clk_2;
  logic lrcl_clk_1, lrcl_clk_2;
  logic signed [15:0] raw_audio_in_1_singlecycle, raw_audio_in_2_singlecycle;
  logic signed [15:0] raw_audio_in_1, raw_audio_in_2, processed_audio_in_1, processed_audio_in_2;
  logic mic_data_valid_1, mic_data_valid_2;

  i2s mic_1(.audio_clk(audio_clk),
            .rst_in(sys_rst), 
            .mic_data(mic_1_data), 
            .i2s_clk(i2s_clk_1), 
            .lrcl_clk(lrcl_clk_1), 
            .data_valid_out(mic_data_valid_1), 
            .audio_out(raw_audio_in_1_singlecycle));

  i2s mic_2(.audio_clk(audio_clk), 
            .rst_in(sys_rst),
            .mic_data(mic_2_data),
            .i2s_clk(i2s_clk_2),
            .lrcl_clk(lrcl_clk_2),
            .data_valid_out(mic_data_valid_2),
            .audio_out(raw_audio_in_2_singlecycle));

  assign pmodb[3] = i2s_clk_1;
  assign pmodb[7] = i2s_clk_2;
  assign pmodb[2] = lrcl_clk_1;
  assign pmodb[6] = lrcl_clk_2;
  assign mic_1_data = pmoda[3];
  assign mic_2_data = pmoda[7];

  process_audio process_mic_1(.audio_clk(audio_clk),
                              .rst_in(sys_rst),
                              .audio_trigger(audio_trigger),
                              .mic_data_valid(mic_data_valid_1),
                              .raw_audio_single_cycle(raw_audio_in_1_singlecycle),
                              .raw_audio_in(raw_audio_in_1),
                              .processed_audio(processed_audio_in_1));

  process_audio process_mic_2(.audio_clk(audio_clk),
                              .rst_in(sys_rst),
                              .audio_trigger(audio_trigger),
                              .mic_data_valid(mic_data_valid_2),
                              .raw_audio_single_cycle(raw_audio_in_2_singlecycle),
                              .raw_audio_in(raw_audio_in_2),
                              .processed_audio(processed_audio_in_2));


  localparam impulse_length = 16'd24000;
  logic impulse_recorded, able_to_impulse, produced_convolutional_result, impulse_write_enable;
  logic [15:0] impulse_write_addr;
  logic signed [15:0] impulse_response_write_data, impulse_amp_out;
  logic signed [47:0] convolved_audio_singlecycle;
  logic [12:0] first_ir_index, second_ir_index;
  logic signed [15:0] ir_vals [7:0];
  logic ir_data_in_valid;

  ir_buffer #(16'd6000) impulse_memory(
                                   .audio_clk(audio_clk),
                                   .rst_in(sys_rst),
                                   .ir_sample_index(impulse_write_addr),
                                   .write_data(impulse_response_write_data),
                                   .write_enable(impulse_write_enable),
                                   .ir_data_in_valid(ir_data_in_valid),
                                   .first_ir_index(first_ir_index),
                                   .second_ir_index(second_ir_index),
                                   .ir_vals(ir_vals)
                                   );

  record_impulse #(impulse_length) impulse_recording(
                                   .audio_clk(audio_clk),
                                   .rst_in(sys_rst),
                                   .audio_trigger(audio_trigger),
                                   .record_impulse_trigger(btn[3]),
                                   .delay_length(DELAY_AMOUNT),
                                   .audio_in(processed_audio_in_1),
                                   .impulse_recorded(impulse_recorded),
                                   .ir_sample_index(impulse_write_addr),
                                   .ir_data_in_valid(ir_data_in_valid),
                                   .write_data(impulse_response_write_data),
                                   .write_enable(impulse_write_enable),
                                   .impulse_amp_out(impulse_amp_out)
                                   );

  convolve_audio #(impulse_length) convolving_audio(
                                   .audio_clk(audio_clk),
                                   .rst_in(sys_rst),
                                   .audio_trigger(audio_trigger),
                                   .audio_in(processed_audio_in_2),
                                   .impulse_in_memory_complete(impulse_recorded),
                                   .convolution_result(convolved_audio_singlecycle),
                                   .produced_convolutional_result(produced_convolutional_result),
                                   .first_ir_index(first_ir_index),
                                   .second_ir_index(second_ir_index),
                                   .ir_vals(ir_vals)
                                  );  
  
  logic signed [15:0] displayed_audio_1, displayed_audio_2, convolved_audio;
  always_ff @(posedge audio_clk) begin
    if (produced_convolutional_result) begin
      convolved_audio <= (-16'sd1 * convolved_audio_singlecycle[28:13]);
    end
    if (btn[2]) begin
      displayed_audio_1 <= processed_audio_in_1;
      displayed_audio_2 <= processed_audio_in_2;
    end
  end

  /// ### SEVEN SEGMENT DISPLAY
  logic [6:0] ss_c;
  assign ss0_c = ss_c; 
  assign ss1_c = ss_c;

  seven_segment_controller mssc(.clk_in(audio_clk),
                              .rst_in(sys_rst),
                              .val_in(sw[9] ? (convolved_audio): {displayed_audio_1, displayed_audio_2}),
                              .cat_out(ss_c),
                              .an_out({ss0_an, ss1_an}));

  // ### TEST SINE WAVE

  logic signed [7:0] tone_440; 
  sine_generator sine_440 (
    .clk_in(audio_clk),
    .rst_in(sys_rst),
    .step_in(audio_trigger),
    .amp_out(tone_440)
  ); 
  defparam sine_440.PHASE_INCR = 32'b0000_0100_1011_0001_0111_1110_0100_1011;

  // ### Allpass speaker phase correction
  logic allpassed_valid;
  logic signed [15:0] allpassed_singlecycle, allpassed;
  fir_allpass_24k_16width_output allpass(.aclk(audio_clk),
                                          .s_axis_data_tvalid(audio_trigger),
                                          .s_axis_data_tready(1'b1),
                                          .s_axis_data_tdata(convolved_audio),
                                          .m_axis_data_tvalid(allpassed_valid),
                                          .m_axis_data_tdata(allpassed_singlecycle));

  always_ff @(posedge audio_clk) begin
    if (allpassed_valid) begin
      allpassed <= allpassed_singlecycle;
    end 
  end

  logic signed [15:0] delayed_audio_out, one_second_delay;
  //Delayed audio by sw[15:10] w/ two 0s tacked on 
  delay_audio #(16'd1000) my_delayed_sound_out (
        .clk_in(audio_clk), 
        .rst_in(sys_rst),
        .enable_delay(1'b1), 
        .delay_length(DELAY_AMOUNT),
        .audio_valid_in(audio_trigger), 
        .audio_in(allpassed), 
        .delayed_audio_out(delayed_audio_out) 
  );

  // One second delayed audio
  delay_audio #(16'd24010) one_second_delayed_sound_out (
        .clk_in(audio_clk),
        .rst_in(sys_rst),
        .enable_delay(1'b1), 
        .delay_length(16'd24000),
        .audio_valid_in(audio_trigger),
        .audio_in(processed_audio_in_2),
        .delayed_audio_out(one_second_delay) 
  );

  // ### SOUND OUTPUT MANAGEMENT

  logic signed [15:0] pdm_out_2;
  logic sound_out_1, sound_out_2;
  
  assign pdm_out_2 = sw[2] ? {{8{tone_440[7]}}, tone_440[7:0]} <<< 8 : 
                    (sw[3] ? raw_audio_in_1 : 
                    (sw[4] ? processed_audio_in_1 : 
                    (sw[5] ? convolved_audio : 
                    (sw[6] ? allpassed : 
                    (sw[7] ? delayed_audio_out :
                    (sw[8] ? processed_audio_in_2 : 0))))));

  pdm pdm1(
    .clk_in(audio_clk),
    .rst_in(sys_rst),
    .level_in(impulse_amp_out),
    .pdm_out(sound_out_1)
  );

  pdm pdm2(
    .clk_in(audio_clk),
    .rst_in(sys_rst),
    .level_in(pdm_out_2),
    .pdm_out(sound_out_2)
  );

  assign spkl = sw[0] ? sound_out_1 : 0;
  assign spkr = sw[1] ? sound_out_2 : 0;

endmodule // top_level
