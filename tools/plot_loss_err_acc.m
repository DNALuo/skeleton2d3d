figure(1);

% choose experiment

dataset = 'penn-crop';

% exp_name = 'hg-256-res-64';
% epoch_size = 4921;  clr = 'r';
% exp_name = 'hg-256-res-64-llprior-w0.001';
% epoch_size = 4921;  clr = 'g';
% exp_name = 'hg-256-res-64-llprior-w1';
% epoch_size = 4921;  clr = 'b';

maxy11 = 50;  maxy21 = 50;
maxy12 = 24;  maxy22 = 24;
maxy13 = 1;   maxy23 = 1;

disp_int = 1000;

% set parameters
max_epoch = 10;

format = '%s %s %s %s %s %s %s';

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
log_file = ['./exp/' dataset '/' exp_name '/train.log'];
f = fopen(log_file);
C = textscan(f,format);
fclose(f);
epoch = cellfun(@(x)str2double(x),C{1}(2:end));
iter = cellfun(@(x)str2double(x),C{2}(2:end));
loss = cellfun(@(x)str2double(x),C{5}(2:end));
err = cellfun(@(x)str2double(x),C{6}(2:end));
acc = cellfun(@(x)str2double(x),C{7}(2:end));

ind = [];
for i = 1:max_epoch
    ii = find(epoch == i);
    if isempty(ii)
        continue
    end
    % sample index uniformly
    ind = [ind; ii(1:disp_int:numel(ii))];  %#ok
    % add the last iter of each epoch
    if ismember(epoch_size*i, ii) && ~ismember(epoch_size*i, ind)
        ind = [ind; epoch_size*i];  %#ok
    end
end
it = (epoch(ind)-1)*epoch_size + iter(ind);

subplot('Position',[0.02+0/3 0.56 1/3-0.03 0.4]);
plot(it,loss(ind),['-' clr]); hold on;
grid on;
axis([0 it(end) ylim]);
title('training loss');
xlabel('iteration');

subplot('Position',[0.02+1/3 0.56 1/3-0.03 0.4]);
plot(it,err(ind),['-' clr]); hold on;
grid on;
axis([0 it(end) ylim]);
title('training error');
xlabel('iteration');

subplot('Position',[0.02+2/3 0.56 1/3-0.03 0.4]);
plot(it,acc(ind),['-' clr]); hold on;
grid on;
axis([0 it(end) ylim]);
title('training acc');
xlabel('iteration');
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
log_file = ['./exp/' dataset '/' exp_name '/val.log'];
f = fopen(log_file);
C = textscan(f,format);
fclose(f);
epoch = cellfun(@(x)str2double(x),C{1}(2:end));
iter = cellfun(@(x)str2double(x),C{2}(2:end));
loss = cellfun(@(x)str2double(x),C{5}(2:end));
err = cellfun(@(x)str2double(x),C{6}(2:end));
acc = cellfun(@(x)str2double(x),C{7}(2:end));

it = (epoch-1)*epoch_size + iter;
ii = mod(1:numel(it),10) == 0;

subplot('Position',[0.02+0/3 0.06 1/3-0.03 0.4]);
plot(it,loss,['-' clr]); hold on;
plot(it(ii),loss(ii),['o' clr],'MarkerSize',5);
grid on;
title('validation loss');
xlabel('iteration');

subplot('Position',[0.02+1/3 0.06 1/3-0.03 0.4]);
plot(it,err,['-' clr]); hold on;
plot(it(ii),err(ii),['o' clr],'MarkerSize',5);
grid on;
title('validation error');
xlabel('iteration');

subplot('Position',[0.02+2/3 0.06 1/3-0.03 0.4]);
plot(it,acc,['-' clr]); hold on;
plot(it(ii),acc(ii),['o' clr],'MarkerSize',5);
grid on;
title('validation acc');
xlabel('iteration');
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

subplot('Position',[0.02+0/3 0.56 1/3-0.03 0.4]); set(gca,'fontsize',6);
subplot('Position',[0.02+1/3 0.56 1/3-0.03 0.4]); set(gca,'fontsize',6);
subplot('Position',[0.02+2/3 0.56 1/3-0.03 0.4]); set(gca,'fontsize',6);
subplot('Position',[0.02+0/3 0.06 1/3-0.03 0.4]); set(gca,'fontsize',6);
subplot('Position',[0.02+1/3 0.06 1/3-0.03 0.4]); set(gca,'fontsize',6);
subplot('Position',[0.02+2/3 0.06 1/3-0.03 0.4]); set(gca,'fontsize',6);

subplot('Position',[0.02+0/3 0.56 1/3-0.03 0.4]);
lim = [xlim, ylim];
axis([lim(1:2) 0 maxy11]);
subplot('Position',[0.02+0/3 0.06 1/3-0.03 0.4]);
axis([lim(1:2) 0 maxy21]);

subplot('Position',[0.02+1/3 0.56 1/3-0.03 0.4]);
lim = [xlim, ylim];
axis([lim(1:2) 0 maxy12]);
subplot('Position',[0.02+1/3 0.06 1/3-0.03 0.4]);
axis([lim(1:2) 0 maxy22]);

subplot('Position',[0.02+2/3 0.56 1/3-0.03 0.4]);
lim = [xlim, ylim];
axis([lim(1:2) 0 maxy13]);
subplot('Position',[0.02+2/3 0.06 1/3-0.03 0.4]);
axis([lim(1:2) 0 maxy23]);

% save to file
save_file = ['outputs/plot_' exp_name '.pdf'];
if ~exist(save_file,'file')
    set(gcf,'PaperPosition',[0 0 11 6]);
    set(gcf,'PaperOrientation','landscape');
    print(gcf,save_file,'-dpdf');
end

close;