%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% Yi-Chao Chen
%% 2013.10.26 @ UT Austin
%%
%% - Input:
%%   @option_swap_mat: determine how to arrange rows and columns of TM
%%      0: original matrix
%%      1: randomize raw and col
%%      2: geo
%%      3: correlated coefficient
%%   @option_type: determine the way to remove unimportant parts
%%      0: remove those values which are close to 0
%%      1: remove chunks which cause smallest errors
%%
%% - Output:
%%
%% e.g. 
%%     [tp, tn, fp, fn, precision, recall, f1score] = dct_based('/u/yichao/anomaly_compression/condor_data/subtask_inject_error/TM_err/', 'TM_Airport_period5_.exp0.', 12, 300, 300, 4, 50, 0, 0, 50, 50, 10, 20)
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

function [tp, tn, fp, fn, precision, recall, f1score] = dct_based(input_TM_dir, filename, num_frames, width, height, group_size, thresh, option_swap_mat, option_type, chunk_width, chunk_height, selcted_chunk, quantization)
    addpath('/u/yichao/anomaly_compression/utils/mirt_dctn');
    addpath('/u/yichao/anomaly_compression/utils');


    %% --------------------
    %% DEBUG
    %% --------------------
    DEBUG0 = 0;
    DEBUG1 = 1;
    DEBUG2 = 1;
    DEBUG3 = 0; %% block index check

    if width ~= height
        fprintf('width should be equal to height: %d, %d\n', width, height);
        return;
    end


    %% --------------------
    %% Constant
    %% --------------------
    % quantization = 10;


    %% --------------------
    %% Variable
    %% --------------------
    % input_TM_dir   = '/u/yichao/anomaly_compression/condor_data/subtask_inject_error/TM_err/';
    input_errs_dir = '/u/yichao/anomaly_compression/condor_data/subtask_inject_error/errs/';
    input_4sq_dir  = '/u/yichao/anomaly_compression/condor_data/subtask_process_4sq/TM/';


    %% --------------------
    %% Main starts
    %% --------------------
    num_chunks = [ceil(width/chunk_width), ceil(height/chunk_height)];
    num_groups = ceil(num_frames / group_size);


    %% --------------------
    %% Read anomaly ground truth
    %%  - row 1: index
    %%  - row 2: anomaly value
    %% Read data matrix
    %% --------------------
    if DEBUG2, fprintf('read anomalies\n'); end

    data = zeros(width, height, num_frames);
    raw_gt_frame = cell(1, num_frames);
    for frame = [0:num_frames-1]
        if DEBUG0, fprintf('  frame %d\n', frame); end

        this_err_file = [input_errs_dir filename int2str(frame) '.err.txt'];
        if DEBUG0, fprintf('    file = %s\n', this_err_file); end

        if frame == 0
            ground_truth = load(this_err_file);
            raw_gt_frame(frame+1) = {ground_truth(1, :)};
        else
            tmp = load(this_err_file);
            raw_gt_frame(frame+1) = {tmp(1, :)};

            tmp(1, :) = tmp(1, :) + frame * width * height;
            ground_truth = [ground_truth, tmp];
        end

        %% load data matrix
        this_matrix_file = [input_TM_dir filename int2str(frame) '.txt'];
        if DEBUG0, fprintf('    file = %s\n', this_matrix_file); end
        
        tmp = load(this_matrix_file);
        data(:,:,frame+1) = tmp(1:width, 1:height);
    end


    %% --------------------
    %% swap matrix row and column
    %% 0: original matrix
    %% 1: randomize raw and col
    %% 2: geo
    %% 3: correlated coefficient
    %% --------------------
    if DEBUG2, fprintf('swap matrix row and column\n'); end

    if option_swap_mat == 0
        %% 0: original matrix
        mapping = [1:width];
    elseif option_swap_mat == 1
        %% 1: randomize raw and col
        mapping = randperm(width);
    elseif option_swap_mat == 2
        %% 2: geo
        [location, mass] = get_venue_info([input_4sq_dir filename], '4sq', width, height);
        if DEBUG0
            fprintf('  size of location: %d, %d\n', size(location));
            fprintf('  size of mass: %d, %d\n', size(mass));
        end
        
        mapping = sort_by_lat_lng(location, width, height);

    elseif option_swap_mat == 3
        %% 3: correlated coefficient
        tmp = reshape(data, width, []);
        if DEBUG1
            fprintf('  size of the whole matrix: %d, %d\n', size(tmp));
        end
        
        coef = corrcoef(tmp');
        mapping = sort_by_coef(coef, width, height);
    end

    %% update the data matrix and ground truth according to the mapping
    for f = [1:num_frames]
        data(:,:,f) = map_matrix(data(:,:,f), mapping);

        %% update ground truth
        new_ind = find_mapping_ind(raw_gt_frame{f}, width, height, mapping);
        if f == 1
            gt_tmp = new_ind;
        else
            gt_tmp = [gt_tmp, (new_ind + (f-1) * width * height)];
        end
    end

    ground_truth(1, :) = gt_tmp;

    if DEBUG1, fprintf('  size of ground truth: %d, %d\n', size(ground_truth)); end
    if DEBUG1, fprintf('  size of data matrix: %d, %d, %d\n', size(data)); end
    

    %% --------------------
    %% apply 3D DCT to each Group of Pictures (GoP)
    %% --------------------
    for gop = 1:num_groups
        gop_s = (gop - 1) * group_size + 1;
        gop_e = min(num_frames, gop * group_size);

        if DEBUG1 == 0, fprintf('gop %d: frame %d-%d\n', gop, gop_s, gop_e); end

        this_group = data(:, :, gop_s:gop_e);

        if option_type == 0
            %% ignore elements which are close to 0
            est_group  = mirt_idctn(round(mirt_dctn(this_group) / quantization) * quantization);
        elseif option_type == 1
            %% ignore chunks which cause smaller errors

            %% calculate error caused by each chunk
            this_group_dct = mirt_dctn(this_group);
            err_bit_map = zeros(num_chunks(1), num_chunks(2), gop_e-gop_s+1);
            for w = 1:num_chunks(1)
                w_s = (w-1)*chunk_width + 1;
                w_e = min(w*chunk_width, width);
                
                for h = 1:num_chunks(2)
                    h_s = (h-1)*chunk_height + 1;
                    h_e = min(h*chunk_height, height);

                    for f = 1:(gop_e-gop_s+1)
                        tmp = this_group_dct;
                        tmp(w_s:w_e, h_s:h_e, f) = 0;
                        tmp_est_gp = mirt_idctn(tmp);

                        err_bit_map(w, h, f) = mean(abs(tmp_est_gp(:) - this_group(:)));

                        if DEBUG0, fprintf('  chunk [%d, %d, %d], err=%f\n', w, h, f, err_bit_map(w, h, f)); end
                    end
                end
            end

            %% select chunks which cause larger error
            est_group_dct = zeros(size(this_group_dct));
            [err_sort, err_ind_sort] = sort(err_bit_map(:), 'descend');
            for selected_ind = [1:min(selcted_chunk, length(err_sort))]
                [w, h, f] = convert_3d_ind(num_chunks(1), num_chunks(2), (gop_e-gop_s+1), err_ind_sort(selected_ind));
                
                if DEBUG0, fprintf('%d [%d, %d, %d], err = %f (%f)\n', err_ind_sort(selected_ind), w, h, f, err_bit_map(err_ind_sort(selected_ind)), err_sort(selected_ind)); end

                w_s = (w-1)*chunk_width + 1;
                w_e = min(w*chunk_width, width);
                h_s = (h-1)*chunk_height + 1;
                h_e = min(h*chunk_height, height);
                est_group_dct(w_s:w_e, h_s:h_e, f) = this_group_dct(w_s:w_e, h_s:h_e, f);
            end

            est_group  = mirt_idctn(est_group_dct);
        end

        %% ------------
        %% detect anomaly
        err_ts = abs(this_group(:) - est_group(:));
        this_group_err_ind = find(err_ts > thresh);
        if gop == 1
            detect_err_ind = this_group_err_ind;
        else
            detect_err_ind = [detect_err_ind; this_group_err_ind + (gop-1)*width*height*group_size];
        end
        if DEBUG1, fprintf('    size of detect err = %d, %d\n', size(detect_err_ind)); end
        
    end
    

    tps = intersect(ground_truth(1, :), detect_err_ind);
    tp = size(tps, 2);
    fps = setdiff(detect_err_ind, ground_truth(1, :));
    fp = size(fps, 2);
    fns = setdiff(ground_truth(1, :), detect_err_ind);
    fn = size(fns, 2);
    tn = size(err_ts(:, 1), 1) - tp - fp - fn;
    
    precision = tp / (tp + fp);
    recall = tp / (tp + fn);
    f1score = 2 * precision * recall / (precision + recall);
end



%% -------------------------------------
%% map_matrix: swap row and columns according to "mapping"
%% @input mapping: 
%%    a vector to map venues to the other
%%    e.g. [4, 3, 1, 2] means mapping 1->4, 2->3, 3->1, 4->2
%%
function [new_mat] = map_matrix(mat, mapping)
    new_mat = zeros(size(mat));
    new_mat(mapping, :) = mat;
    tmp = new_mat;
    new_mat(:, mapping) = tmp;
end


%% find_ind: function description
function [map_ind] = find_mapping_ind(ind, width, height, mapping)
    y = mod(ind-1, height) + 1;
    x = floor((ind-1)/height) + 1;

    x2 = mapping(x);
    y2 = mapping(y);
    map_ind = (x2 - 1) * height + y2;
end


%% -------------------------------------
%% sort_by_lat_lng
%% @input location: 
%%    a Nx2 matrix to represent the (lat, lng) of N venues
%%
function [mapping] = sort_by_lat_lng(location, width, height)
    mapping = ones(1, width);
    tmp = 2:width;
    src = 1;
    src_ind = 2;
    while length(tmp) > 0
        min_dist = -1;
        min_dist_dst = 0;
        min_dist_ind = 0;

        ind = 0;
        for dst = tmp
            ind = ind + 1;
            dist = pos2dist(location(src,1), location(src,2), location(dst,1), location(dst,2), 2);

            if (min_dist == -1) | (min_dist > dist) 
                min_dist = dist;
                min_dist_dst = dst;
                min_dist_ind = ind;
            end
        end

        if tmp(min_dist_ind) ~= min_dist_dst
            fprintf('min dist dst does not match: %d, %d\n', tmp(min_dist_ind), min_dist_dst);
            return;
        end

        mapping(src_ind) = min_dist_dst;
        src = min_dist_dst;
        src_ind = src_ind + 1;
        tmp(min_dist_ind) = [];
    end
end


%% -------------------------------------
%% sort_by_coef
%% @input coef: 
%%    a NxN matrix to represent the correlation coefficient of N venues
%%
function [mapping] = sort_by_coef(coef, width, height)
    mapping = ones(1, width);
    tmp = 2:width;
    src = 1;
    src_ind = 2;
    while length(tmp) > 0
        max_coef = -1;
        max_coef_dst = 0;
        max_coef_ind = 0;

        ind = 0;
        for dst = tmp
            ind = ind + 1;
            this_coef = coef(src, dst);

            if (max_coef == -1) | (this_coef > max_coef) 
                max_coef = this_coef;
                max_coef_dst = dst;
                max_coef_ind = ind;
            end
        end

        if tmp(max_coef_ind) ~= max_coef_dst
            fprintf('max coef dst does not match: %d, %d\n', tmp(max_coef_ind), max_coef_dst);
            return;
        end

        mapping(src_ind) = max_coef_dst;
        src = max_coef_dst;
        src_ind = src_ind + 1;
        tmp(max_coef_ind) = [];
    end
end


%% convert_3d_ind
function [x, y, z] = convert_3d_ind(w, h, f, line_ind)
    z = floor( (line_ind - 1) / (w*h)) + 1;
    y = floor( (line_ind - (z-1) * (w*h) - 1 ) / w) + 1;
    x = floor( (line_ind - (z-1) * (w*h) - (y-1) * w) );
end