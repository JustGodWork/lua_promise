require "promise.class.lua"; -- Implement your own require path

---@param callbackFn fun(count: number)
local function my_count(callbackFn)
    local count = 0;
    while (count < 10) do
        count = count + 1;
    end
    callbackFn(count);
end

local function count_method_1()
    local promise = Promise();
    my_count(function(count)
        promise:Resolve(count);
    end);
    return promise:Await();
end

local function count_method_2()
    return Promise(function(resolve, reject)
        my_count(function(count)
            resolve(count);
        end);
    end);
end

local function count_method_3()
    local promise = Promise();
    my_count(function(count)
        promise:Resolve(count);
    end);
    return promise;
end

local function count_method_4()
    local promise = Promise();
    my_count(function(count)
        local random_error = math.random(1, 2);
        if (random_error == 1) then
            promise:Reject("Random error");
            return;
        end
        promise:Resolve(count);
    end);
    return promise;
end

async(function()
    local my_method_one_number = count_method_1();
    print(("My method 1 number is %s"):format(my_method_one_number));
    local my_method_two_number = await(count_method_2());
    print(("My method 2 number is %s"):format(my_method_two_number));
    local my_method_three_number = await(count_method_3());
    print(("My method 3 number is %s"):format(my_method_three_number));
    count_method_4():Then(function(count)
        print(("My method 4 number is %s"):format(count));
    end, function(reason)
        print(("My method 4 failed with reason: %s"):format(reason));
    end);
    count_method_4():Catch(function(reason)
        print(("My method 4 failed with reason: %s"):format(reason));
    end);
end);