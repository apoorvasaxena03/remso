function [x] = setStateValues(stateValue,varargin)
%
%  Given a structure with physical state values, i.e., (pressure,sW) or
%  (pressure,sW,rGH) for 2-phase or 3-phase respectively, provide a remso
%  state with these values.  If a optional 'x' value is given, the state
%  will be modified according to the optional parameters


opt = struct('x',[],'cells',[],'nCells',[],'xScale',[]);
opt = merge_options(opt, varargin{:});



if isempty(opt.x)  %%
    if numel(stateValue.pressure) == 1
        if isfield(stateValue,'rGH')
            x = [ones(opt.nCells,1)*stateValue.pressure;
                ones(opt.nCells,1)*stateValue.sW;
                ones(opt.nCells,1)*stateValue.rGH];
        else
            x = [ones(opt.nCells,1)*stateValue.pressure;
                ones(opt.nCells,1)*stateValue.sW];
        end
        
    else %% assuming that correct dimensions are given!
        if isfield(stateValue,'rGH')
            x = [stateValue.pressure;
                stateValue.sW;
                stateValue.rGH];
        else
            x = [stateValue.pressure;
                stateValue.sW];
        end
        
    end
else
    
    if ~isempty(opt.xScale)
        x = opt.x.*opt.xScale;
    else
        x = opt.x;
    end
    
    if  isfield(stateValue,'pressure')
        x(opt.cells) = stateValue.pressure;
    end
    if  isfield(stateValue,'sW')
        x(opt.cells+opt.nCells) = stateValue.sW;
    end
    if isfield(stateValue,'rGH')
        x(opt.cells+2*opt.nCells) = stateValue.rGH;
    end
    
end


if ~isempty(opt.xScale)
    x = x./opt.xScale;
end



end
