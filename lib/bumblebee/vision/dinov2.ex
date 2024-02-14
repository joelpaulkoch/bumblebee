defmodule Bumblebee.Vision.DinoV2 do
  alias Bumblebee.Shared

  options =
    [
      image_size: [
        default: 518,
        doc: "the size of the input spatial dimensions"
      ],
      num_channels: [
        default: 3,
        doc: "the number of channels in the input"
      ],
      patch_size: [
        default: 14,
        doc: "the size of the patch spatial dimensions"
      ],
      hidden_size: [
        default: 384,
        doc: "the dimensionality of hidden layers"
      ],
      num_blocks: [
        default: 12,
        doc: "the number of Transformer blocks in the encoder"
      ],
      num_attention_heads: [
        default: 12,
        doc: "the number of attention heads for each attention layer in the encoder"
      ],
      mlp_ratio: [
        default: 4,
        docs: "Ratio of the hidden size of the MLPs relative to `:hidden_size`"
      ],
      use_qkv_bias: [
        default: true,
        doc: "whether to use bias in query, key, and value projections"
      ],
      activation: [
        default: :gelu,
        doc: "the activation function"
      ],
      dropout_rate: [
        default: 0.0,
        doc: "the dropout rate for encoder and decoder"
      ],
      attention_dropout_rate: [
        default: 0.0,
        doc: "the dropout rate for attention weights"
      ],
      layer_norm_epsilon: [
        default: 1.0e-6,
        doc: "the epsilon used by the layer normalization layers"
      ],
      initializer_scale: [
        default: 0.02,
        doc:
          "the standard deviation of the normal initializer used for initializing kernel parameters"
      ],
      layerscale_value: [
        default: 1.0,
        doc: "the initial value to use for layer scale"
      ],
      drop_path_rate: [
        default: 0.0,
        doc:
          "the stochastic depth rate per sample (when applied in the main path of residual layers)"
      ],
      swiglu_ffn: [
        default: false,
        doc: "whether to use the SwiGLU feedforward neural network"
      ],
      stage_names: [
        default: [],
        doc: "the names of the stages of the model when used as backbone"
      ],
      output_features: [
        default: [],
        doc:
          "If used as backbone, list of features to output. Can be any of `stem`, `stage1`, `stage2`,
           etc. (depending on how many stages the model has). If unset and `out_indices` is set,
           will default to the corresponding stages. If unset and `out_indices` is unset, will default to the last stage.
           Must be in the same order as defined in the `stage_names` attribute."
      ],
      #       out_indices: [
      #         default: nil,
      #         doc:
      #           "            If used as backbone, list of indices of features to output. Can be any of 0, 1, 2, etc. (depending on how
      #             many stages the model has). If unset and `out_features` is set, will default to the corresponding stages.
      #             If unset and `out_features` is unset, will default to the last stage. Must be in the
      #             same order as defined in the `stage_names` attribute."
      #       ],
      apply_layernorm: [
        default: true,
        doc:
          "whether to apply layer normalization to the feature maps in case the model is used as backbone"
      ],
      reshape_hidden_states: [
        default: true,
        doc:
          "Whether to reshape the feature maps to 4D tensors of shape `(batch_size, hidden_size, height, width)` in
           case the model is used as backbone. If `False`, the feature maps will be 3D tensors of shape `(batch_size,
           seq_len, hidden_size)`."
      ]
    ] ++
      Shared.common_options([
        :output_hidden_states,
        :output_attentions,
        :num_labels,
        :id_to_label
      ])

  @moduledoc """
  DinoV2 model.

  ## Architectures

    * `:base` - plain DinoV2 without any head on top

    * `:backbone` - outputs feature maps

    * `:for_image_classification` - DinoV2 with head for image classification
  ## Inputs

    * `"pixel_values"` - `{batch_size, image_size, image_size, num_channels}`

      Featurized image pixel values.

    * `"patch_mask"` - `{batch_size, num_patches}`

      Mask to nullify selected embedded patches.

  ## Configuration

  #{Shared.options_doc(options)}

  ## References

    * [DINOv2: Learning Robust Visual Features without Supervision](https://arxiv.org/abs/2304.07193)

  """

  defstruct [architecture: :base] ++ Shared.option_defaults(options)

  @behaviour Bumblebee.ModelSpec
  @behaviour Bumblebee.Configurable

  import Bumblebee.Utils.Model, only: [join: 2]

  alias Bumblebee.Layers

  @impl true
  def architectures(), do: [:base, :backbone, :for_image_classification]

  @impl true
  def config(spec, opts) do
    spec
    |> Shared.put_config_attrs(opts)
    |> Shared.validate_label_options()
  end

  @impl true
  def input_template(spec) do
    %{
      "pixel_values" => Nx.template({1, 224, 224, spec.num_channels}, :f32)
    }
  end

  @impl true
  def model(%__MODULE__{architecture: :base} = spec) do
    spec
    |> inputs()
    |> core(spec)
    |> base_output(spec)
    |> Layers.output()
  end

  @impl true
  def model(%__MODULE__{architecture: :backbone} = spec) do
    spec = Shared.put_config_attrs(spec, output_hidden_states: true)

    spec
    |> inputs()
    |> core(spec)
    |> backbone_output(spec)
    |> Layers.output()
  end

  def model(%__MODULE__{architecture: :for_image_classification} = spec) do
    outputs =
      inputs(spec)
      |> core(spec)
      |> base_output(spec)

    class_token =
      outputs.hidden_state
      |> Layers.take_token(index: 0, axis: 1)
      |> Axon.reshape({:batch, 1, :auto})

    patch_embeddings_mean =
      Axon.nx(outputs.hidden_state, fn hidden_state ->
        patch_embeddings = hidden_state[[.., 1..-1//1, ..]]
        Nx.mean(patch_embeddings, axes: [1], keep_axes: true)
      end)

    logits =
      Axon.concatenate(class_token, patch_embeddings_mean)
      |> Axon.dense(spec.num_labels,
        kernel_initializer: kernel_initializer(spec),
        name: "image_classification_head.output"
      )

    Layers.output(%{
      logits: logits,
      hidden_states: outputs.hidden_states,
      attentions: outputs.attentions
    })
  end

  defp inputs(spec) do
    shape = {nil, 224, 224, spec.num_channels}

    Bumblebee.Utils.Model.inputs_to_map([
      Axon.input("pixel_values", shape: shape),
      Axon.input("patch_mask", shape: {nil, nil}, optional: true)
    ])
  end

  defp core(inputs, spec, opts \\ []) do
    name = opts[:name]

    embeddings =
      embedder(inputs["pixel_values"], inputs["patch_mask"], spec, name: join(name, "embedder"))

    encoder(embeddings, spec, name: join(name, "encoder"))
  end

  defp base_output(encoder_outputs, spec, opts \\ []) do
    name = opts[:name]

    hidden_state =
      Axon.layer_norm(encoder_outputs.hidden_state,
        epsilon: spec.layer_norm_epsilon,
        name: join(name, "norm")
      )

    pooled = Layers.take_token(hidden_state, index: 0, axis: 1)

    %{
      hidden_state: hidden_state,
      pooled_state: pooled,
      hidden_states: encoder_outputs.hidden_states,
      attentions: encoder_outputs.attentions
    }
  end

  defp feature_map(hidden_states, index, spec, opts) do
    name = opts[:name]

    {_, input_size, _, _} = Axon.get_inputs(hidden_states)["pixel_values"]
    num_patches = div(input_size, spec.patch_size)

    hidden_state =
      Axon.nx(hidden_states, fn states -> elem(states, index) end)

    hidden_state =
      if spec.apply_layernorm do
        Axon.layer_norm(hidden_state, epsilon: spec.layer_norm_epsilon, name: join(name, "norm"))
      else
        hidden_state
      end

    if spec.reshape_hidden_states do
      Axon.nx(hidden_state, fn tensor -> tensor[[.., 1..-1//1, ..]] end)
      |> Axon.reshape({:batch, num_patches, num_patches, :auto})
    else
      hidden_state
    end
  end

  defp backbone_output(encoder_outputs, spec, opts \\ []) do
    name = opts[:name]

    hidden_states = encoder_outputs.hidden_states

    stage_names = spec.stage_names
    output_features = spec.output_features

    feature_maps =
      for {stage_name, index} <- Enum.with_index(stage_names),
          stage_name in output_features,
          reduce: %{} do
        acc ->
          Map.put(
            acc,
            stage_name,
            feature_map(hidden_states, index, spec, name: join(name, "feature_map"))
          )
      end

    %{
      feature_maps: feature_maps,
      hidden_states: encoder_outputs.hidden_states,
      attentions: encoder_outputs.attentions
    }
  end

  defp interpolate_position_encoding(
         position_embeddings,
         input_size,
         spec
       ) do
    original_positions = div(spec.image_size, spec.patch_size)
    resized_positions = div(input_size, spec.patch_size)

    class_position_embedding =
      Layers.take_token(position_embeddings, index: 0, axis: 1)
      |> Axon.reshape({1, 1, spec.hidden_size})

    other_position_embeddings =
      Axon.nx(position_embeddings, fn tensor -> tensor[[.., 1..-1//1, ..]] end)

    interpolated_embeddings =
      other_position_embeddings
      |> Axon.reshape({:batch, original_positions, original_positions, spec.hidden_size})
      |> Axon.resize({resized_positions, resized_positions}, method: :bicubic)
      |> Axon.reshape({:batch, :auto, spec.hidden_size})

    Layers.concatenate_embeddings([class_position_embedding, interpolated_embeddings])
  end

  defp embedder(pixel_values, patch_mask, spec, opts) do
    name = opts[:name]

    patch_embeddings =
      pixel_values
      |> patch_embedding(spec, name: join(name, "patch_embedding"))
      |> Layers.apply_vision_patch_mask(patch_mask, name: join(name, "mask_tokens"))

    class_embedding =
      Layers.learned_embeddings(1, spec.hidden_size, name: join(name, "class_embedding"))

    input_embeddings = Layers.concatenate_embeddings([class_embedding, patch_embeddings])

    num_patches = div(spec.image_size, spec.patch_size) ** 2

    {_, input_size, _, _} = Axon.get_inputs(pixel_values)["pixel_values"]

    position_embeddings =
      Layers.learned_embeddings(num_patches + 1, spec.hidden_size,
        initializer: :zeros,
        name: join(name, "position_embedding")
      )
      |> interpolate_position_encoding(input_size, spec)

    Axon.add(input_embeddings, position_embeddings)
    |> Axon.dropout(rate: spec.dropout_rate, name: join(name, "dropout"))
  end

  defp patch_embedding(pixel_values, spec, opts) do
    name = opts[:name]

    pixel_values
    |> Axon.conv(spec.hidden_size,
      kernel_size: spec.patch_size,
      strides: spec.patch_size,
      padding: :valid,
      kernel_initializer: kernel_initializer(spec),
      name: join(name, "projection")
    )
    |> Axon.reshape({:batch, :auto, spec.hidden_size}, name: join(name, "reshape"))
  end

  defp mlp(input, name, spec) do
    hidden_features = spec.hidden_size * spec.mlp_ratio

    out_features = spec.hidden_size

    input
    |> Axon.dense(hidden_features, name: name |> join("mlp") |> join("fc1"))
    |> Bumblebee.Layers.activation(spec.activation)
    |> Axon.dense(out_features, name: name |> join("mlp") |> join("fc2"))
  end

  defp swiglu(input, name, spec) do
    hidden_features =
      div(round(round(spec.hidden_size * spec.mlp_ratio) * 2 / 3 + 7), 8) * 8

    output_features = spec.hidden_size

    hidden_state =
      input
      |> Axon.dense(2 * hidden_features, name: name |> join("swiglu") |> join("weights_in"))

    {x1, x2} = Axon.split(hidden_state, 2)

    Axon.silu(x1)
    |> Axon.multiply(x2)
    |> Axon.dense(output_features, name: name |> join("swiglu") |> join("weights_out"))
  end

  defp encoder(hidden_state, spec, opts) do
    name = opts[:name]

    ffn = if spec.swiglu_ffn, do: &swiglu(&1, &2, spec), else: &mlp(&1, &2, spec)

    blocks(hidden_state,
      num_blocks: spec.num_blocks,
      num_attention_heads: spec.num_attention_heads,
      hidden_size: spec.hidden_size,
      kernel_initializer: kernel_initializer(spec),
      dropout_rate: spec.dropout_rate,
      attention_dropout_rate: spec.attention_dropout_rate,
      query_use_bias: spec.use_qkv_bias,
      key_use_bias: spec.use_qkv_bias,
      value_use_bias: spec.use_qkv_bias,
      layer_norm: [
        epsilon: spec.layer_norm_epsilon
      ],
      ffn: ffn,
      block_type: :norm_first_with_scale,
      output_hidden_states: spec.output_hidden_states,
      output_attentions: spec.output_attentions,
      name: join(name, "blocks")
    )
  end

  defp kernel_initializer(spec) do
    Axon.Initializers.normal(scale: spec.initializer_scale)
  end

  defimpl Bumblebee.HuggingFace.Transformers.Config do
    def load(spec, data) do
      import Shared.Converters

      opts =
        convert!(data,
          image_size: {"image_size", number()},
          num_channels: {"num_channels", number()},
          patch_size: {"patch_size", number()},
          hidden_size: {"hidden_size", number()},
          num_blocks: {"num_hidden_layers", number()},
          num_attention_heads: {"num_attention_heads", number()},
          mlp_ratio: {"mlp_ratio", number()},
          activation: {"hidden_act", activation()},
          use_qkv_bias: {"qkv_bias", boolean()},
          dropout_rate: {"hidden_dropout_prob", number()},
          attention_dropout_rate: {"attention_probs_dropout_prob", number()},
          layer_norm_epsilon: {"layer_norm_eps", number()},
          initializer_scale: {"initializer_range", number()},
          layerscale_value: {"layerscale_value", number()},
          drop_path_rate: {"drop_path_rate", number()},
          swiglu_ffn: {"use_swiglu_ffn", boolean()},
          stage_names: {"stage_names", list(string())},
          output_features: {"_out_features", list(string())},
          apply_layernorm: {"apply_layernorm", boolean()}
        ) ++ Shared.common_options_from_transformers(data, spec)

      @for.config(spec, opts)
    end
  end

  defimpl Bumblebee.HuggingFace.Transformers.Model do
    def params_mapping(_spec) do
      %{
        "embedder.patch_embedding.projection" => "dinov2.embeddings.patch_embeddings.projection",
        "embedder.class_embedding" => %{
          "embeddings" => {
            [{"dinov2.embeddings", "cls_token"}],
            fn [value] -> Nx.squeeze(value, axes: [0]) end
          }
        },
        "embedder.position_embedding" => %{
          "embeddings" => {
            [{"dinov2.embeddings", "position_embeddings"}],
            fn [value] -> Nx.squeeze(value, axes: [0]) end
          }
        },
        "encoder.blocks.{n}.self_attention_norm" => "dinov2.encoder.layer.{n}.norm1",
        "encoder.blocks.{n}.self_attention.key" =>
          "dinov2.encoder.layer.{n}.attention.attention.key",
        "encoder.blocks.{n}.self_attention.query" =>
          "dinov2.encoder.layer.{n}.attention.attention.query",
        "encoder.blocks.{n}.self_attention.value" =>
          "dinov2.encoder.layer.{n}.attention.attention.value",
        "encoder.blocks.{n}.self_attention.output" =>
          "dinov2.encoder.layer.{n}.attention.output.dense",
        "encoder.blocks.{n}.ffn.mlp.fc1" => "dinov2.encoder.layer.{n}.mlp.fc1",
        "encoder.blocks.{n}.ffn.mlp.fc2" => "dinov2.encoder.layer.{n}.mlp.fc2",
        "encoder.blocks.{n}.ffn.swiglu.weights_in" => "dinov2.encoder.layer.{n}.mlp.weights_in",
        "encoder.blocks.{n}.ffn.swiglu.weights_out" => "dinov2.encoder.layer.{n}.mlp.weights_out",
        "encoder.blocks.{n}.layer_scale1" => %{
          "scale" => {
            [{"dinov2.encoder.layer.{n}.layer_scale1", "lambda1"}],
            fn [lambda1] -> lambda1 end
          }
        },
        "encoder.blocks.{n}.layer_scale2" => %{
          "scale" => {
            [{"dinov2.encoder.layer.{n}.layer_scale2", "lambda1"}],
            fn [lambda1] -> lambda1 end
          }
        },
        "encoder.blocks.{n}.ffn.intermediate" => "dinov2.encoder.layer.{n}.intermediate.dense",
        "encoder.blocks.{n}.ffn.output" => "dinov2.encoder.layer.{n}.output.dense",
        "encoder.blocks.{n}.output_norm" => "dinov2.encoder.layer.{n}.norm2",
        "norm" => "dinov2.layernorm",
        "image_classification_head.output" => "classifier"
      }
    end
  end

  defp blocks(hidden_state, opts) do
    validate_required_keys!(opts, [:num_blocks, :num_attention_heads, :hidden_size, :ffn])

    block_opts_keys = [
      :num_attention_heads,
      :num_key_value_heads,
      :causal,
      :hidden_size,
      :ffn,
      :kernel_initializer,
      :attention_head_size,
      :dropout_rate,
      :attention_dropout_rate,
      :query_use_bias,
      :key_use_bias,
      :value_use_bias,
      :output_use_bias,
      :layer_norm,
      :block_type,
      :scale_attention_weights,
      :rotary_embedding
    ]

    opts =
      Keyword.validate!(
        opts,
        block_opts_keys ++
          [
            :name,
            :num_blocks,
            attention_mask: Layers.none(),
            attention_head_mask: Layers.none(),
            attention_relative_bias: nil,
            share_attention_relative_bias: false,
            cross_hidden_state: nil,
            cross_attention_mask: Layers.none(),
            cross_attention_head_mask: Layers.none(),
            cache: Layers.none(),
            output_hidden_states: false,
            output_attentions: false
          ]
      )

    name = opts[:name]
    num_blocks = opts[:num_blocks]
    output_hidden_states = opts[:output_hidden_states]
    output_attentions = opts[:output_attentions]

    attention_mask = opts[:attention_mask]
    attention_head_mask = opts[:attention_head_mask]
    cross_hidden_state = opts[:cross_hidden_state]
    cross_attention_mask = opts[:cross_attention_mask]
    cross_attention_head_mask = opts[:cross_attention_head_mask]
    cache = opts[:cache]

    block_opts = Keyword.take(opts, block_opts_keys)

    {attention_mask, cache} = Layers.Decoder.cached_attention_mask(attention_mask, cache)
    offset = Layers.Decoder.get_cache_offset(cache)

    state = %{
      hidden_state: hidden_state,
      hidden_states: Layers.maybe_container({hidden_state}, output_hidden_states),
      attentions: Layers.maybe_container({}, output_attentions),
      cross_attentions: Layers.maybe_container({}, output_attentions),
      cache: cache,
      attention_relative_bias: Layers.none()
    }

    outputs =
      for idx <- 0..(num_blocks - 1), reduce: state do
        state ->
          block_attention_head_mask = Axon.nx(attention_head_mask, & &1[idx])
          block_cross_attention_head_mask = Axon.nx(cross_attention_head_mask, & &1[idx])
          block_cache = Layers.Decoder.get_block_cache(state.cache, idx)

          attention_relative_bias =
            if opts[:share_attention_relative_bias] and idx > 0 do
              state.attention_relative_bias
            else
              opts[:attention_relative_bias] || Layers.none()
            end

          {hidden_state, attention, cross_attention, block_cache, attention_relative_bias} =
            block(
              state.hidden_state,
              [
                attention_mask: attention_mask,
                attention_head_mask: block_attention_head_mask,
                attention_relative_bias: attention_relative_bias,
                cross_hidden_state: cross_hidden_state,
                cross_attention_mask: cross_attention_mask,
                cross_attention_head_mask: block_cross_attention_head_mask,
                block_cache: block_cache,
                offset: offset,
                name: join(name, idx)
              ] ++ block_opts
            )

          cache = Layers.Decoder.put_block_cache(state.cache, idx, block_cache)

          %{
            hidden_state: hidden_state,
            hidden_states: Layers.append(state.hidden_states, hidden_state),
            attentions: Layers.append(state.attentions, attention),
            cross_attentions: Layers.append(state.cross_attentions, cross_attention),
            attention_relative_bias: attention_relative_bias,
            cache: cache
          }
      end

    update_in(outputs.cache, &Layers.Decoder.update_cache_offset(&1, hidden_state))
  end

  defp block(hidden_state, opts) do
    validate_required_keys!(opts, [:num_attention_heads, :hidden_size, :ffn])

    opts =
      Keyword.validate!(opts, [
        :name,
        :num_attention_heads,
        :hidden_size,
        :ffn,
        :num_key_value_heads,
        attention_mask: Layers.none(),
        attention_head_mask: Layers.none(),
        attention_relative_bias: Layers.none(),
        cross_hidden_state: nil,
        cross_attention_mask: Layers.none(),
        cross_attention_head_mask: Layers.none(),
        block_cache: Layers.none(),
        offset: Layers.none(),
        causal: false,
        kernel_initializer: :glorot_uniform,
        attention_head_size: nil,
        dropout_rate: 0.0,
        attention_dropout_rate: 0.0,
        query_use_bias: true,
        key_use_bias: true,
        value_use_bias: true,
        output_use_bias: true,
        block_type: :standard,
        layer_norm: [],
        scale_attention_weights: true,
        rotary_embedding: nil
      ])

    name = opts[:name]
    num_attention_heads = opts[:num_attention_heads]
    num_key_value_heads = opts[:num_key_value_heads] || num_attention_heads
    hidden_size = opts[:hidden_size]
    ffn = opts[:ffn]
    causal = opts[:causal]
    kernel_initializer = opts[:kernel_initializer]
    attention_head_size = opts[:attention_head_size]
    dropout_rate = opts[:dropout_rate]
    attention_dropout_rate = opts[:attention_dropout_rate]
    query_use_bias = opts[:query_use_bias]
    key_use_bias = opts[:key_use_bias]
    value_use_bias = opts[:value_use_bias]
    output_use_bias = opts[:output_use_bias]
    attention_mask = opts[:attention_mask]
    attention_head_mask = opts[:attention_head_mask]
    attention_relative_bias = opts[:attention_relative_bias]
    cross_hidden_state = opts[:cross_hidden_state]
    cross_attention_mask = opts[:cross_attention_mask]
    cross_attention_head_mask = opts[:cross_attention_head_mask]
    block_cache = opts[:block_cache]
    offset = opts[:offset]
    layer_norm = opts[:layer_norm]
    block_type = opts[:block_type]
    scale_attention_weights = opts[:scale_attention_weights]
    rotary_embedding = opts[:rotary_embedding]

    ffn_fun =
      case ffn do
        opts when is_list(opts) ->
          validate_required_keys!(opts, [:intermediate_size])
          opts = Keyword.validate!(opts, [:intermediate_size, activation: :gelu])

          &basic_ffn(&1, opts[:intermediate_size], hidden_size,
            activation: opts[:activation],
            kernel_initializer: kernel_initializer,
            dropout_rate: dropout_rate,
            name: &2
          )

        fun when is_function(fun) ->
          fun
      end

    layer_norm_fun =
      case layer_norm do
        opts when is_list(opts) ->
          opts = Keyword.validate!(opts, epsilon: 1.0e-5)

          &Axon.layer_norm(&1, epsilon: opts[:epsilon], name: &2)

        fun when is_function(fun) ->
          fun
      end

    {self_attention_cache, cross_attention_cache} =
      Layers.Decoder.get_attention_caches(block_cache)

    # Self-attention, shortcut connection, normalization and dropout

    self_attention_norm = &layer_norm_fun.(&1, join(name, "self_attention_norm"))

    self_attention = fn hidden_state ->
      {hidden_state, attention, self_attention_cache, attention_relative_bias} =
        Bumblebee.Layers.Transformer.multi_head_attention(
          hidden_state,
          hidden_state,
          hidden_state,
          attention_mask: attention_mask,
          attention_head_mask: attention_head_mask,
          attention_relative_bias: attention_relative_bias,
          attention_cache: self_attention_cache,
          offset: offset,
          causal: causal,
          num_heads: num_attention_heads,
          num_key_value_heads: num_key_value_heads,
          hidden_size: hidden_size,
          kernel_initializer: kernel_initializer,
          attention_head_size: attention_head_size,
          dropout_rate: attention_dropout_rate,
          query_use_bias: query_use_bias,
          key_use_bias: key_use_bias,
          value_use_bias: value_use_bias,
          output_use_bias: output_use_bias,
          scale_attention_weights: scale_attention_weights,
          rotary_embedding: rotary_embedding,
          name: join(name, "self_attention")
        )

      hidden_state =
        Axon.dropout(hidden_state, rate: dropout_rate, name: join(name, "self_attention_dropout"))

      {hidden_state, {attention, self_attention_cache, attention_relative_bias}}
    end

    # Cross-attention, shortcut connection, normalization and dropout

    cross_attention_maybe = fn hidden_state, fun ->
      if cross_hidden_state do
        Layers.if_present cross_hidden_state do
          fun.(hidden_state)
        else
          {hidden_state, {Layers.none(), cross_attention_cache}}
        end
      else
        {hidden_state, {Layers.none(), cross_attention_cache}}
      end
    end

    cross_attention_norm = &layer_norm_fun.(&1, join(name, "cross_attention_norm"))

    cross_attention = fn hidden_state ->
      {hidden_state, cross_attention, cross_attention_cache, _cross_attention_relative_bias} =
        Bumblebee.Layers.Transformer.multi_head_attention(
          hidden_state,
          cross_hidden_state,
          cross_hidden_state,
          attention_mask: cross_attention_mask,
          attention_head_mask: cross_attention_head_mask,
          attention_cache: cross_attention_cache,
          offset: offset,
          num_heads: num_attention_heads,
          num_key_value_heads: num_key_value_heads,
          hidden_size: hidden_size,
          kernel_initializer: kernel_initializer,
          attention_head_size: attention_head_size,
          dropout_rate: attention_dropout_rate,
          query_use_bias: query_use_bias,
          key_use_bias: key_use_bias,
          value_use_bias: value_use_bias,
          output_use_bias: output_use_bias,
          scale_attention_weights: scale_attention_weights,
          rotary_embedding: rotary_embedding,
          name: join(name, "cross_attention")
        )

      hidden_state =
        Axon.dropout(
          hidden_state,
          rate: dropout_rate,
          name: join(name, "cross_attention_dropout")
        )

      {hidden_state, {cross_attention, cross_attention_cache}}
    end

    # Output feed-forward network, shortcut connection, normalization and dropout

    output_norm = &layer_norm_fun.(&1, join(name, "output_norm"))

    ffn =
      &ffn_fun.(&1, join(name, "ffn"))

    scale1 = &Bumblebee.Layers.scale(&1, name: join(name, "layer_scale1"))
    scale2 = &Bumblebee.Layers.scale(&1, name: join(name, "layer_scale2"))

    {hidden_state, attention_info, cross_attention_info} =
      block_impl(
        block_type,
        hidden_state,
        self_attention_norm,
        self_attention,
        scale1,
        scale2,
        cross_attention_maybe,
        cross_attention_norm,
        cross_attention,
        output_norm,
        ffn
      )

    {attention, self_attention_cache, attention_relative_bias} = attention_info
    {cross_attention, cross_attention_cache} = cross_attention_info

    block_cache =
      Layers.Decoder.put_attention_caches(
        block_cache,
        self_attention_cache,
        cross_attention_cache
      )

    {hidden_state, attention, cross_attention, block_cache, attention_relative_bias}
  end

  defp block_impl(
         :norm_first_with_scale,
         hidden_state,
         self_attention_norm,
         self_attention,
         scale1,
         scale2,
         cross_attention_maybe,
         cross_attention_norm,
         cross_attention,
         output_norm,
         ffn
       ) do
    shortcut = hidden_state

    {hidden_state, attention_info} =
      hidden_state
      |> self_attention_norm.()
      |> self_attention.()

    hidden_state =
      scale1.(hidden_state)
      |> Axon.add(shortcut)

    {hidden_state, cross_attention_info} =
      cross_attention_maybe.(hidden_state, fn hidden_state ->
        shortcut = hidden_state

        {hidden_state, cross_attention_info} =
          hidden_state
          |> cross_attention_norm.()
          |> cross_attention.()

        hidden_state = Axon.add(hidden_state, shortcut)

        {hidden_state, cross_attention_info}
      end)

    shortcut = hidden_state

    hidden_state =
      hidden_state
      |> output_norm.()
      |> ffn.()
      |> scale2.()
      |> Axon.add(shortcut)

    {hidden_state, attention_info, cross_attention_info}
  end

  defp basic_ffn(x, intermediate_size, output_size, opts) do
    name = opts[:name]

    x
    |> Axon.dense(intermediate_size,
      kernel_initializer: opts[:kernel_initializer],
      name: join(name, "intermediate")
    )
    |> Layers.activation(opts[:activation])
    |> Axon.dense(output_size,
      kernel_initializer: opts[:kernel_initializer],
      name: join(name, "output")
    )
    |> Axon.dropout(rate: opts[:dropout_rate])
  end

  defp validate_required_keys!(opts, keys) do
    case keys -- Keyword.keys(opts) do
      [] -> :ok
      missing -> raise ArgumentError, "missing required options: #{inspect(missing)}"
    end
  end
end