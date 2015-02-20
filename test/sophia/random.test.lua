
-- random

space = box.schema.create_space('test', { engine = 'sophia'})
index = space:create_index('primary', { type = 'tree', parts = {1, 'num'} })

dofile('index_random_test.lua')
index_random_test(space, 'primary')

space:drop()
sophia_schedule()
